// swiftlint:disable file_length

import Foundation
import Result
import ReactiveSwift
import ReactiveTask
import XCDBLD

/// A producer representing a scheme to be built.
///
/// A producer of this type will send the project and scheme name when building
/// begins, then complete or error when building terminates.
public typealias BuildSchemeProducer = SignalProducer<TaskEvent<(ProjectLocator, Scheme)>, CarthageError>

/// A callback static function used to determine whether or not an SDK should be built
public typealias SDKFilterCallback = (_ sdks: [SDK], _ scheme: Scheme, _ configuration: String, _ project: ProjectLocator) -> Result<[SDK], CarthageError>

typealias ProjectScheme = (project: ProjectLocator, scheme: Scheme)

public final class Xcode {
    
    private static let buildSettingsCache = Cache<BuildArguments, Result<[BuildSettings], CarthageError>>()
    private static let destinationsCache = Cache<SDK, Result<String?, CarthageError>>()

    /// Attempts to build the dependency, then places its build product into the
    /// root directory given.
    ///
    /// Returns producers in the same format as buildInDirectory().
    static func build(
        dependency: Dependency,
        version: PinnedVersion,
        rootDirectoryURL: URL,
        withOptions options: BuildOptions,
        lockTimeout: Int? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) },
        builtProductsHandler: (([URL]) -> SignalProducer<(), CarthageError>)? = nil
        ) -> BuildSchemeProducer {
        let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
        let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()

        return buildInDirectory(dependencyURL,
                                withOptions: options,
                                dependency: (dependency, version),
                                rootDirectoryURL: rootDirectoryURL,
                                lockTimeout: lockTimeout,
                                sdkFilter: sdkFilter,
                                builtProductsHandler: builtProductsHandler
            ).mapError { error in
                switch (dependency, error) {
                case let (_, .noSharedFrameworkSchemes(_, platforms)):
                    return .noSharedFrameworkSchemes(dependency, platforms)

                case let (.gitHub(repo), .noSharedSchemes(project, _)):
                    return .noSharedSchemes(project, repo)

                default:
                    return error
                }
        }
    }

    /// Builds the any shared framework schemes found within the given directory.
    ///
    /// Returns a signal of all standard output from `xcodebuild`, and each scheme being built.
    static func buildInDirectory( // swiftlint:disable:this static function_body_length
        _ directoryURL: URL,
        withOptions options: BuildOptions,
        dependency: (dependency: Dependency, version: PinnedVersion)? = nil,
        rootDirectoryURL: URL,
        lockTimeout: Int? = nil,
        customProjectName: String? = nil,
        customCommitish: String? = nil,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) },
        builtProductsHandler: (([URL]) -> SignalProducer<(), CarthageError>)? = nil
        ) -> BuildSchemeProducer {
        precondition(directoryURL.isFileURL)

        var lock: Lock?
        return URLLock.lockReactive(url: URL(fileURLWithPath: options.derivedDataPath ?? Constants.Dependency.derivedDataURL.path), timeout: lockTimeout)
            .flatMap(.merge) { urlLock -> BuildSchemeProducer in
                lock = urlLock

                let schemeMatcher = SchemeCartfile.from(directoryURL: directoryURL).value?.matcher

                return BuildSchemeProducer { observer, lifetime in
                    // Use SignalProducer.replayLazily to avoid enumerating the given directory
                    // multiple times.
                    return SignalProducer(result: buildableSchemesInDirectory(directoryURL, withConfiguration: options.configuration, forPlatforms: options.platforms, schemeMatcher: schemeMatcher))
                        .flatten()
                        .flatMap(.concat) { projectScheme -> SignalProducer<TaskEvent<URL>, CarthageError> in
                            let initialValue = projectScheme

                            let wrappedSDKFilter: SDKFilterCallback = { sdks, scheme, configuration, project in
                                let filteredSDKs: [SDK]
                                if options.platforms.isEmpty {
                                    filteredSDKs = sdks
                                } else {
                                    filteredSDKs = sdks.filter { options.platforms.contains($0.platform) }
                                }
                                return sdkFilter(filteredSDKs, scheme, configuration, project)
                            }

                            return buildScheme(
                                projectScheme.scheme,
                                withOptions: options,
                                inProject: projectScheme.project,
                                rootDirectoryURL: rootDirectoryURL,
                                workingDirectoryURL: directoryURL,
                                sdkFilter: wrappedSDKFilter
                                )
                                .mapError { error -> CarthageError in
                                    if case let .taskError(taskError) = error {
                                        return .buildFailed(taskError, log: nil)
                                    } else {
                                        return error
                                    }
                                }
                                .on(started: {
                                    observer.send(value: .success(initialValue))
                                })
                        }
                        .collectTaskEvents()
                        .flatMapTaskEvents(.concat) { (urls: [URL]) -> SignalProducer<(), CarthageError> in
                            if let dependency = dependency {
                                return VersionFile.createVersionFile(
                                    for: dependency.dependency,
                                    version: dependency.version,
                                    platforms: options.platforms,
                                    configuration: options.configuration,
                                    buildProducts: urls,
                                    rootDirectoryURL: rootDirectoryURL
                                    ).then(builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty)
                            } else {
                                // Is only possible if the current project is a git repository, because the version file is tied to commit hash
                                if rootDirectoryURL.isGitDirectory {
                                    return VersionFile.createVersionFileForCurrentProject(
                                        projectName: customProjectName, 
                                        commitish: customCommitish,
                                        platforms: options.platforms,
                                        configuration: options.configuration,
                                        buildProducts: urls,
                                        rootDirectoryURL: rootDirectoryURL
                                        ).then(builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty)
                                } else {
                                    return builtProductsHandler?(urls) ?? SignalProducer<(), CarthageError>.empty
                                }
                            }
                        }
                        // Discard any Success values, since we want to
                        // use our initial value instead of waiting for
                        // completion.
                        .map { taskEvent -> TaskEvent<(ProjectLocator, Scheme)> in
                            let ignoredValue = (ProjectLocator.workspace(URL(string: ".")!), Scheme(""))
                            return taskEvent.map { _ in ignoredValue }
                        }
                        .filter { taskEvent in
                            taskEvent.value == nil
                        }
                        .startWithSignal({ signal, signalDisposable in
                            lifetime += signalDisposable
                            signal.observe(observer)
                        })
                }
            }.on(terminated: {
                lock?.unlock()
            })
    }
    
    private static func projectSchemes(directoryURL: URL) -> Result<[ProjectLocator:[Scheme]], CarthageError> {
        return ProjectLocator
            .locate(in: directoryURL)
            .flatMap({ projects -> CarthageResult<[ProjectLocator:[Scheme]]> in
                return CarthageResult.catching { () -> [ProjectLocator:[Scheme]] in
                    try projects.reduce(into: [ProjectLocator:[Scheme]]()) { dict, project in
                        dict[project, default: [Scheme]()].append(contentsOf: try project.schemes().get())
                    }
                }
            })
    }

    /// Finds schemes of projects or workspaces, which Carthage should build, found
    /// within the given directory.
    static func buildableSchemesInDirectory( // swiftlint:disable:this static function_body_length
        _ directoryURL: URL,
        withConfiguration configuration: String,
        forPlatforms platforms: Set<Platform> = [],
        schemeMatcher: SchemeMatcher?
        ) -> Result<[ProjectScheme], CarthageError> {
        precondition(directoryURL.isFileURL)
        
        return CarthageResult.catching { () -> [ProjectScheme] in
        
            let projectSchemes: [ProjectLocator: [Scheme]] = try self.projectSchemes(directoryURL: directoryURL).get()
            
            if projectSchemes.isEmpty {
                // No schemes and no projects: just return
                return []
            }
            
            var ret = [ProjectScheme]()
            
            //TODO: construct workspace lookup dictionary, by reading the contents of the workspace
            let workspaceLookupDict = [ProjectLocator: ProjectLocator]()
            
            for (project, schemes) in projectSchemes where !project.isWorkspace {
                for scheme in schemes {
                    let buildArguments = BuildArguments(project: project, scheme: scheme, configuration: configuration)
                    if shouldBuildScheme(buildArguments, forPlatforms: platforms, schemeMatcher: schemeMatcher).value == true {
                        if let workspace = workspaceLookupDict[project] {
                            ret.append((workspace, scheme))
                        } else {
                            ret.append((project, scheme))
                        }
                    }
                }
            }
            return ret
        }
    }

    /// Invokes `xcodebuild` to retrieve build settings for the given build
    /// arguments.
    ///
    /// Upon .success, sends one BuildSettings value for each target included in
    /// the referenced scheme.
    static func loadBuildSettings(with arguments: BuildArguments, for action: BuildArguments.Action? = nil) -> CarthageResult<[BuildSettings]> {
        // xcodebuild (in Xcode 8.0) has a bug where xcodebuild -showBuildSettings
        // can hang indefinitely on projects that contain core data models.
        // rdar://27052195
        // Including the action "clean" works around this issue, which is further
        // discussed here: https://forums.developer.apple.com/thread/50372
        //
        // "archive" also works around the issue above so use it to determine if
        // it is configured for the archive action.
        
        return buildSettingsCache.getValue(key: arguments) { arguments in
            let task = xcodebuildTask(["archive", "-showBuildSettings", "-skipUnavailableActions"], arguments)
            return task.launch()
                .ignoreTaskData()
                .mapError(CarthageError.taskError)
                // xcodebuild has a bug where xcodebuild -showBuildSettings
                // can sometimes hang indefinitely on projects that don't
                // share any schemes, so automatically bail out if it looks
                // like that's happening.
                .timeout(after: 60, raising: .xcodebuildTimeout(arguments.project), on: QueueScheduler(qos: .default))
                .map { data in
                    return String(data: data, encoding: .utf8)!
                }
                .only()
                .map {
                    return BuildSettings.parseBuildSettings(string: $0, arguments: arguments, action: action)
                }
        }
    }

    // MARK: - Internal

    /// Strips a framework from unexpected architectures and potentially debug symbols,
    /// optionally codesigning the result.
    /// This method is used in a test case, but it should be private
    static func stripFramework(
        _ frameworkURL: URL,
        keepingArchitectures: [String],
        strippingDebugSymbols: Bool,
        codesigningIdentity: String? = nil
        ) -> Result<(), CarthageError> {

        return stripBinary(frameworkURL, keepingArchitectures: keepingArchitectures)
            .flatMap {
                strippingDebugSymbols ? stripDebugSymbols(frameworkURL) : .success(())
            }
            .flatMap {
                stripHeadersDirectory(frameworkURL)
            }
            .flatMap {
                stripPrivateHeadersDirectory(frameworkURL)
            }
            .flatMap {
                stripModulesDirectory(frameworkURL)
            }
            .flatMap {
                codesigningIdentity.map({ codesign(frameworkURL, $0) }) ?? .success(())
            }
    }

    /// Strips a universal file from unexpected architectures.
    static func stripBinary(_ binaryURL: URL, keepingArchitectures: [String]) -> CarthageResult<()> {
        return Frameworks.architecturesInPackage(binaryURL)
            .filter { !keepingArchitectures.contains($0) }
            .flatMap(.concat) { stripArchitecture(binaryURL, $0) }
            .wait()
    }

    // MARK: - Private

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ tasks: [String], _ buildArguments: BuildArguments) -> Task {
        return Task("/usr/bin/xcrun", arguments: buildArguments.arguments + tasks)
    }

    /// Creates a task description for executing `xcodebuild` with the given
    /// arguments.
    private static func xcodebuildTask(_ task: String, _ buildArguments: BuildArguments) -> Task {
        return xcodebuildTask([task], buildArguments)
    }

    /// Finds the built product for the given settings, then copies it (preserving
    /// its name) into the given folder. The folder will be created if it does not
    /// already exist.
    ///
    /// If this built product has any *.bcsymbolmap files they will also be copied.
    ///
    /// Returns a signal that will send the URL after copying upon .success.
    private static func copyBuildProductIntoDirectory(_ directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, CarthageError> {
        let target = settings.wrapperName.map(directoryURL.appendingPathComponent)
        return SignalProducer(result: target.fanout(settings.wrapperURL))
            .flatMap(.merge) { target, source in
                return Files.copyFile(from: source.resolvingSymlinksInPath(), to: target)
            }
            .flatMap(.merge) { url in
                return copyBCSymbolMapsForBuildProductIntoDirectory(directoryURL, settings)
                    .then(SignalProducer<URL, CarthageError>(value: url))
        }
    }

    /// Finds any *.bcsymbolmap files for the built product and copies them into
    /// the given folder. Does nothing if bitcode is disabled.
    ///
    /// Returns a signal that will send the URL after copying for each file.
    private static func copyBCSymbolMapsForBuildProductIntoDirectory(_ directoryURL: URL, _ settings: BuildSettings) -> SignalProducer<URL, CarthageError> {
        if settings.bitcodeEnabled.value == true {
            return SignalProducer(result: settings.wrapperURL)
                .flatMap(.merge) { wrapperURL in Frameworks.BCSymbolMapsForFramework(wrapperURL) }
                .copyFileURLsIntoDirectory(directoryURL)
        } else {
            return .empty
        }
    }

    /// Attempts to merge the given executables into one fat binary, written to
    /// the specified URL.
    private static func mergeExecutables(_ executableURLs: [URL], _ outputURL: URL) -> SignalProducer<(), CarthageError> {
        precondition(outputURL.isFileURL)

        return SignalProducer<URL, CarthageError>(executableURLs)
            .attemptMap { url -> Result<String, CarthageError> in
                if url.isFileURL {
                    return .success(url.path)
                } else {
                    return .failure(.parseError(description: "expected file URL to built executable, got \(url)"))
                }
            }
            .collect()
            .flatMap(.merge) { executablePaths -> SignalProducer<TaskEvent<Data>, CarthageError> in
                let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-create" ] + executablePaths + [ "-output", outputURL.path ])

                return lipoTask.launch()
                    .mapError(CarthageError.taskError)
            }
            .then(SignalProducer<(), CarthageError>.empty)
    }

    private static func mergeSwiftHeaderFiles(_ simulatorExecutableURL: URL,
                                              _ deviceExecutableURL: URL,
                                              _ executableOutputURL: URL) -> SignalProducer<(), CarthageError> {
        precondition(simulatorExecutableURL.isFileURL)
        precondition(deviceExecutableURL.isFileURL)
        precondition(executableOutputURL.isFileURL)

        let includeTargetConditionals = """
                                    #ifndef TARGET_OS_SIMULATOR
                                    #include <TargetConditionals.h>
                                    #endif\n
                                    """
        let conditionalPrefix = "#if TARGET_OS_SIMULATOR\n"
        let conditionalElse = "\n#else\n"
        let conditionalSuffix = "\n#endif\n"

        let includeTargetConditionalsContents = includeTargetConditionals.data(using: .utf8)!
        let conditionalPrefixContents = conditionalPrefix.data(using: .utf8)!
        let conditionalElseContents = conditionalElse.data(using: .utf8)!
        let conditionalSuffixContents = conditionalSuffix.data(using: .utf8)!

        guard let simulatorHeaderURL = simulatorExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }
        guard let simulatorHeaderContents = FileManager.default.contents(atPath: simulatorHeaderURL.path) else { return .empty }
        guard let deviceHeaderURL = deviceExecutableURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }
        guard let deviceHeaderContents = FileManager.default.contents(atPath: deviceHeaderURL.path) else { return .empty }
        guard let outputURL = executableOutputURL.deletingLastPathComponent().swiftHeaderURL() else { return .empty }

        var fileContents = Data()

        fileContents.append(includeTargetConditionalsContents)
        fileContents.append(conditionalPrefixContents)
        fileContents.append(simulatorHeaderContents)
        fileContents.append(conditionalElseContents)
        fileContents.append(deviceHeaderContents)
        fileContents.append(conditionalSuffixContents)

        if FileManager.default.createFile(atPath: outputURL.path, contents: fileContents) {
            return .empty
        } else {
            return .init(error: .writeFailed(outputURL, nil))
        }
    }

    /// If the given source URL represents an LLVM module, copies its contents into
    /// the destination module.
    ///
    /// Sends the URL to each file after copying.
    private static func mergeModuleIntoModule(_ sourceModuleDirectoryURL: URL, _ destinationModuleDirectoryURL: URL) -> SignalProducer<URL, CarthageError> {
        precondition(sourceModuleDirectoryURL.isFileURL)
        precondition(destinationModuleDirectoryURL.isFileURL)

        return FileManager.default.reactive
            .enumerator(at: sourceModuleDirectoryURL, includingPropertiesForKeys: [], options: [ .skipsSubdirectoryDescendants, .skipsHiddenFiles ], catchErrors: true)
            .attemptMap { _, url -> Result<URL, CarthageError> in
                let lastComponent = url.lastPathComponent
                let destinationURL = destinationModuleDirectoryURL.appendingPathComponent(lastComponent).resolvingSymlinksInPath()

                return Result(at: destinationURL, attempt: {
                    try FileManager.default.copyItem(at: url, to: $0, avoiding·rdar·32984063: true)
                    return $0
                })
        }
    }

    /// Determines whether the specified framework type should be built automatically.
    private static func shouldBuildFrameworkType(_ frameworkType: FrameworkType?) -> Bool {
        return frameworkType != nil
    }

    /// Determines whether the given scheme should be built automatically.
    private static func shouldBuildScheme(_ buildArguments: BuildArguments, forPlatforms: Set<Platform>, schemeMatcher: SchemeMatcher?) -> CarthageResult<Bool> {
        precondition(buildArguments.scheme != nil)

        guard schemeMatcher?.matches(scheme: buildArguments.scheme!) ?? true else {
            return .success(false)
        }

        return loadBuildSettings(with: buildArguments)
            .map { settingsArray in
                return settingsArray.contains { (settings) -> Bool in
                    if settings.frameworkType.value == nil {
                        return false
                    }
                    
                    if forPlatforms.isEmpty {
                        return true
                    }
                    
                    let buildSDKs = settings.buildSDKs.value ?? []
                    return buildSDKs.contains {forPlatforms.contains($0.platform) }
                }
            }
    }

    /// Aggregates all of the build settings sent on the given signal, associating
    /// each with the name of its target.
    ///
    /// Returns a signal which will send the aggregated dictionary upon completion
    /// of the input signal, then itself complete.
    private static func settingsByTarget<Error>(_ producer: SignalProducer<TaskEvent<BuildSettings>, Error>) -> SignalProducer<TaskEvent<[String: BuildSettings]>, Error> {
        return SignalProducer { observer, lifetime in
            var settings: [String: BuildSettings] = [:]

            producer.startWithSignal { signal, signalDisposable in
                lifetime += signalDisposable

                signal.observe { event in
                    switch event {
                    case let .value(settingsEvent):
                        let transformedEvent = settingsEvent.map { settings in [ settings.target: settings ] }

                        if let transformed = transformedEvent.value {
                            settings.merge(transformed) { _, new in new }
                        } else {
                            observer.send(value: transformedEvent)
                        }

                    case let .failed(error):
                        observer.send(error: error)

                    case .completed:
                        observer.send(value: .success(settings))
                        observer.sendCompleted()

                    case .interrupted:
                        observer.sendInterrupted()
                    }
                }
            }
        }
    }

    /// Combines the built products corresponding to the given settings, by creating
    /// a fat binary of their executables and merging any Swift modules together,
    /// generating a new built product in the given directory.
    ///
    /// In order for this process to make any sense, the build products should have
    /// been created from the same target, and differ only in the SDK they were
    /// built for.
    ///
    /// Any *.bcsymbolmap files for the built products are also copied.
    ///
    /// Upon .success, sends the URL to the merged product, then completes.
    private static func mergeBuildProducts(
        deviceBuildSettings: BuildSettings,
        simulatorBuildSettings: BuildSettings,
        into destinationFolderURL: URL
        ) -> SignalProducer<URL, CarthageError> {
        return copyBuildProductIntoDirectory(destinationFolderURL, deviceBuildSettings)
            .flatMap(.merge) { productURL -> SignalProducer<URL, CarthageError> in
                let executableURLs = (deviceBuildSettings.executableURL.fanout(simulatorBuildSettings.executableURL)).map { [ $0, $1 ] }
                let outputURL = deviceBuildSettings.executablePath.map(destinationFolderURL.appendingPathComponent)

                let mergeProductBinaries = SignalProducer(result: executableURLs.fanout(outputURL))
                    .flatMap(.concat) { (executableURLs: [URL], outputURL: URL) -> SignalProducer<(), CarthageError> in
                        return mergeExecutables(
                            executableURLs.map { $0.resolvingSymlinksInPath() },
                            outputURL.resolvingSymlinksInPath()
                        )
                }

                let mergeProductSwiftHeaderFilesIfNeeded = SignalProducer.zip(simulatorBuildSettings.executableURL, deviceBuildSettings.executableURL, outputURL)
                    .flatMap(.concat) { (simulatorURL: URL, deviceURL: URL, outputURL: URL) -> SignalProducer<(), CarthageError> in
                        guard Frameworks.isSwiftFramework(productURL) else { return .empty }

                        return mergeSwiftHeaderFiles(
                            simulatorURL.resolvingSymlinksInPath(),
                            deviceURL.resolvingSymlinksInPath(),
                            outputURL.resolvingSymlinksInPath()
                        )
                }

                let sourceModulesURL = SignalProducer(result: simulatorBuildSettings.relativeModulesPath.fanout(simulatorBuildSettings.builtProductsDirectoryURL))
                    .filter { $0.0 != nil }
                    .map { modulesPath, productsURL in
                        return productsURL.appendingPathComponent(modulesPath!)
                }

                let destinationModulesURL = SignalProducer(result: deviceBuildSettings.relativeModulesPath)
                    .filter { $0 != nil }
                    .map { modulesPath -> URL in
                        return destinationFolderURL.appendingPathComponent(modulesPath!)
                }

                let mergeProductModules = SignalProducer.zip(sourceModulesURL, destinationModulesURL)
                    .flatMap(.merge) { (source: URL, destination: URL) -> SignalProducer<URL, CarthageError> in
                        return mergeModuleIntoModule(source, destination)
                }

                return mergeProductBinaries
                    .then(mergeProductSwiftHeaderFilesIfNeeded)
                    .then(mergeProductModules)
                    .then(copyBCSymbolMapsForBuildProductIntoDirectory(destinationFolderURL, simulatorBuildSettings))
                    .then(SignalProducer<URL, CarthageError>(value: productURL))
        }
    }

    /// Builds one scheme of the given project, for all supported SDKs.
    ///
    /// Returns a signal of all standard output from `xcodebuild`, and a signal
    /// which will send the URL to each product successfully built.
    private static func buildScheme( // swiftlint:disable:this static function_body_length cyclomatic_complexity
        _ scheme: Scheme,
        withOptions options: BuildOptions,
        inProject project: ProjectLocator,
        rootDirectoryURL: URL,
        workingDirectoryURL: URL,
        sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
        ) -> SignalProducer<TaskEvent<URL>, CarthageError> {
        precondition(workingDirectoryURL.isFileURL)

        let buildArgs = BuildArguments(
            project: project,
            scheme: scheme,
            configuration: options.configuration,
            derivedDataPath: options.derivedDataPath,
            toolchain: options.toolchain
        )

        return SignalProducer(result: SDKsForScheme(scheme, inProject: project))
            .flatten()
            .flatMap(.concat) { sdk -> SignalProducer<SDK, CarthageError> in
                var argsForLoading = buildArgs
                argsForLoading.sdk = sdk
                let result: CarthageResult<SDK> = loadBuildSettings(with: argsForLoading)
                    .filter { settings in
                        // Filter out SDKs that require bitcode when bitcode is disabled in
                        // project settings. This is necessary for testing frameworks, which
                        // must add a User-Defined setting of ENABLE_BITCODE=NO.
                        return settings.bitcodeEnabled.value == true || ![.tvOS, .watchOS].contains(sdk)
                    }
                    .map { _ in sdk }
                return SignalProducer(result: result)
            }
            .reduce(into: [:]) { (sdksByPlatform: inout [Platform: Set<SDK>], sdk: SDK) in
                let platform = sdk.platform

                if var sdks = sdksByPlatform[platform] {
                    sdks.insert(sdk)
                    sdksByPlatform.updateValue(sdks, forKey: platform)
                } else {
                    sdksByPlatform[platform] = [sdk]
                }
            }
            .flatMap(.concat) { sdksByPlatform -> SignalProducer<(Platform, [SDK]), CarthageError> in
                if sdksByPlatform.isEmpty {
                    fatalError("No SDKs found for scheme \(scheme)")
                }

                let values = sdksByPlatform.map { ($0, Array($1)) }
                return SignalProducer(values)
            }
            .flatMap(.concat) { platform, sdks -> SignalProducer<(Platform, [SDK]), CarthageError> in
                let filterResult = sdkFilter(sdks, scheme, options.configuration, project)
                return SignalProducer(result: filterResult.map { (platform, $0) })
            }
            .filter { _, sdks in
                return !sdks.isEmpty
            }
            .flatMap(.concat) { platform, sdks -> SignalProducer<TaskEvent<URL>, CarthageError> in
                let folderURL = rootDirectoryURL.appendingPathComponent(platform.relativePath, isDirectory: true).resolvingSymlinksInPath()

                switch sdks.count {
                case 1:
                    return build(sdk: sdks[0], with: buildArgs, in: workingDirectoryURL)
                        .flatMapTaskEvents(.merge) { settings in
                            return copyBuildProductIntoDirectory(settings.productDestinationPath(in: folderURL), settings)
                    }

                case 2:
                    let (simulatorSDKs, deviceSDKs) = SDK.splitSDKs(sdks)
                    guard let deviceSDK = deviceSDKs.first else {
                        fatalError("Could not find device SDK in \(sdks)")
                    }
                    guard let simulatorSDK = simulatorSDKs.first else {
                        fatalError("Could not find simulator SDK in \(sdks)")
                    }

                    return settingsByTarget(build(sdk: deviceSDK, with: buildArgs, in: workingDirectoryURL))
                        .flatMap(.concat) { settingsEvent -> SignalProducer<TaskEvent<(BuildSettings, BuildSettings)>, CarthageError> in
                            switch settingsEvent {
                            case let .launch(task):
                                return SignalProducer(value: .launch(task))

                            case let .standardOutput(data):
                                return SignalProducer(value: .standardOutput(data))

                            case let .standardError(data):
                                return SignalProducer(value: .standardError(data))

                            case let .success(deviceSettingsByTarget):
                                return settingsByTarget(build(sdk: simulatorSDK, with: buildArgs, in: workingDirectoryURL))
                                    .flatMapTaskEvents(.concat) { (simulatorSettingsByTarget: [String: BuildSettings]) -> SignalProducer<(BuildSettings, BuildSettings), CarthageError> in
                                        assert(
                                            deviceSettingsByTarget.count == simulatorSettingsByTarget.count,
                                            "Number of targets built for \(deviceSDK) (\(deviceSettingsByTarget.count)) does not match "
                                                + "number of targets built for \(simulatorSDK) (\(simulatorSettingsByTarget.count))"
                                        )

                                        return SignalProducer { observer, lifetime in
                                            for (target, deviceSettings) in deviceSettingsByTarget {
                                                if lifetime.hasEnded {
                                                    break
                                                }

                                                let simulatorSettings = simulatorSettingsByTarget[target]
                                                assert(simulatorSettings != nil, "No \(simulatorSDK) build settings found for target \"\(target)\"")

                                                observer.send(value: (deviceSettings, simulatorSettings!))
                                            }

                                            observer.sendCompleted()
                                        }
                                }
                            }
                        }
                        .flatMapTaskEvents(.concat) { deviceSettings, simulatorSettings in
                            return mergeBuildProducts(
                                deviceBuildSettings: deviceSettings,
                                simulatorBuildSettings: simulatorSettings,
                                into: deviceSettings.productDestinationPath(in: folderURL)
                            )
                    }

                default:
                    fatalError("SDK count \(sdks.count) in scheme \(scheme) is not supported")
                }
            }
            .flatMapTaskEvents(.concat) { builtProductURL -> SignalProducer<URL, CarthageError> in
                return Frameworks.UUIDsForFramework(builtProductURL)
                    // Only attempt to create debug info if there is at least
                    // one dSYM architecture UUID in the framework. This can
                    // occur if the framework is a static framework packaged
                    // like a dynamic framework.
                    .take(first: 1)
                    .flatMap(.concat) { _ -> SignalProducer<URL?, CarthageError> in
                        return SignalProducer(result: createDebugInformation(builtProductURL))
                    }
                    .then(SignalProducer<URL, CarthageError>(value: builtProductURL))
        }
    }

    /// Fixes problem when more than one xcode target has the same Product name for same Deployment target and configuration by deleting TARGET_BUILD_DIR.
    private static func resolveSameTargetName(for settings: BuildSettings) -> CarthageResult<BuildSettings> {
        return settings.targetBuildDirectory.flatMap { buildDir in
            return Task("/usr/bin/xcrun", arguments: ["rm", "-rf", buildDir])
                .launch()
                .mapError(CarthageError.taskError)
                .wait()
                .map {
                    settings
                }
        }
    }
    
    // If SDK is the iOS simulator, then also find and set a valid destination.
    // This fixes problems when the project deployment version is lower than
    // the target's one and includes simulators unsupported by the target.
    //
    // Example: Target is at 8.0, project at 7.0, xcodebuild chooses the first
    // simulator on the list, iPad 2 7.1, which is invalid for the target.
    //
    // See https://github.com/Carthage/Carthage/issues/417.
    private static func fetchDestination(sdk: SDK) -> CarthageResult<String?> {
        // Specifying destination seems to be required for building with
        // simulator SDKs since Xcode 7.2.
        return destinationsCache.getValue(key: sdk) { sdk -> Result<String?, CarthageError> in
            if sdk.isSimulator {
                return Task("/usr/bin/xcrun", arguments: [ "simctl", "list", "devices", "--json" ])
                    .getStdOutData()
                    .mapError(CarthageError.taskError)
                    .flatMap { data -> Result<String?, CarthageError> in
                        if let selectedSimulator = Simulator.selectAvailableSimulator(of: sdk, from: data) {
                            return .success("platform=\(sdk.platform.rawValue) Simulator,id=\(selectedSimulator.udid.uuidString)")
                        } else {
                            return .failure(CarthageError.noAvailableSimulators(platformName: sdk.platform.rawValue))
                        }
                    }
            }
            return .success(nil)
        }
    }

    /// Runs the build for a given sdk and build arguments, optionally performing a clean first
    // swiftlint:disable:next static function_body_length
    private static func build(sdk: SDK, with buildArgs: BuildArguments, in workingDirectoryURL: URL) -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> {
        var argsForLoading = buildArgs
        argsForLoading.sdk = sdk

        var argsForBuilding = argsForLoading
        argsForBuilding.onlyActiveArchitecture = false

        return SignalProducer(result: fetchDestination(sdk: sdk))
            .flatMap(.concat) { destination -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> in
                if let destination = destination {
                    argsForBuilding.destination = destination
                    // Also set the destination lookup timeout. Since we're building
                    // for the simulator the lookup shouldn't take more than a
                    // fraction of a second, but we set to 10 just to be safe.
                    argsForBuilding.destinationTimeout = 10
                }

                // Use `archive` action when building device SDKs to disable LLVM Instrumentation.
                //
                // See https://github.com/Carthage/Carthage/issues/2056
                // and https://developer.apple.com/library/content/qa/qa1964/_index.html.
                let xcodebuildAction: BuildArguments.Action = sdk.isDevice ? .archive : .build
                
                return SignalProducer(result: loadBuildSettings(with: argsForLoading, for: xcodebuildAction))
                    .flatten()
                    .filter { settings in
                        // Only copy build products that are frameworks
                        guard let frameworkType = settings.frameworkType.value, shouldBuildFrameworkType(frameworkType), let projectPath = settings.projectPath.value else {
                            return false
                        }

                        // Do not copy build products that originate from the current project's own carthage dependencies
                        let projectURL = URL(fileURLWithPath: projectPath)
                        let dependencyCheckoutDir = workingDirectoryURL.appendingPathComponent(Constants.checkoutsPath, isDirectory: true)
                        return !dependencyCheckoutDir.hasSubdirectory(projectURL)
                    }
                    .flatMap(.concat) { settings in resolveSameTargetName(for: settings) }
                    .collect()
                    .flatMap(.concat) { settings -> SignalProducer<TaskEvent<BuildSettings>, CarthageError> in
                        let actions: [String] = {
                            var result: [String] = [xcodebuildAction.rawValue]

                            if xcodebuildAction == .archive {
                                result += [
                                    // Prevent generating unnecessary empty `.xcarchive`
                                    // directories.
                                    "-archivePath", (NSTemporaryDirectory() as NSString).appendingPathComponent(workingDirectoryURL.lastPathComponent),

                                    // Disable installing when running `archive` action
                                    // to prevent built frameworks from being deleted
                                    // from derived data folder.
                                    "SKIP_INSTALL=YES",

                                    // Disable the “Instrument Program Flow” build
                                    // setting for both GCC and LLVM as noted in
                                    // https://developer.apple.com/library/content/qa/qa1964/_index.html.
                                    "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO",

                                    // Disable the “Generate Test Coverage Files” build
                                    // setting for GCC as noted in
                                    // https://developer.apple.com/library/content/qa/qa1964/_index.html.
                                    "CLANG_ENABLE_CODE_COVERAGE=NO",

                                    // Disable the "Strip Linked Product" build
                                    // setting so we can later generate a dSYM
                                    "STRIP_INSTALLED_PRODUCT=NO",
                                    
                                    // Enabled whole module compilation since we are not interested in incremental mode
                                    "SWIFT_COMPILATION_MODE=wholemodule",
                                ]
                            }

                            return result
                        }()

                        var buildScheme = xcodebuildTask(actions, argsForBuilding)
                        buildScheme.workingDirectoryPath = workingDirectoryURL.path
                        return buildScheme.launch()
                            .flatMapTaskEvents(.concat) { _ in SignalProducer(settings) }
                            .mapError(CarthageError.taskError)
                }
        }
    }

    /// Creates a dSYM for the provided dynamic framework.
    private static func createDebugInformation(_ builtProductURL: URL) -> CarthageResult<URL?> {
        let dSYMURL = builtProductURL.appendingPathExtension("dSYM")
        let executableName = builtProductURL.deletingPathExtension().lastPathComponent
        if !executableName.isEmpty {
            let executable = builtProductURL.appendingPathComponent(executableName).path
            let dSYM = dSYMURL.path
            let dsymutilTask = Task("/usr/bin/xcrun", arguments: ["dsymutil", executable, "-o", dSYM])
            return dsymutilTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
                .map { _ in dSYMURL }
        } else {
            return .success(nil)
        }
    }

    /// Strips the given architecture from a framework.
    private static func stripArchitecture(_ frameworkURL: URL, _ architecture: String) -> CarthageResult<()> {
        return Frameworks.binaryURL(frameworkURL).flatMap { binaryURL in
            let lipoTask = Task("/usr/bin/xcrun", arguments: [ "lipo", "-remove", architecture, "-output", binaryURL.path, binaryURL.path])
            return lipoTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
        }
    }

    /// Strips debug symbols from the given framework
    private static func stripDebugSymbols(_ frameworkURL: URL) -> CarthageResult<()> {
        return Frameworks.binaryURL(frameworkURL).flatMap { binaryURL in
            let stripTask = Task("/usr/bin/xcrun", arguments: [ "strip", "-S", "-o", binaryURL.path, binaryURL.path])
            return stripTask.launch()
                .mapError(CarthageError.taskError)
                .wait()
        }
    }

    /// Strips `Headers` directory from the given framework.
    private static func stripHeadersDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "Headers", of: frameworkURL)
    }

    /// Strips `PrivateHeaders` directory from the given framework.
    private static func stripPrivateHeadersDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "PrivateHeaders", of: frameworkURL)
    }

    /// Strips `Modules` directory from the given framework.
    private static func stripModulesDirectory(_ frameworkURL: URL) -> CarthageResult<()> {
        return stripDirectory(named: "Modules", of: frameworkURL)
    }

    private static func stripDirectory(named directory: String, of frameworkURL: URL) -> CarthageResult<()> {
        return CarthageResult.catching {
            let directoryURLToStrip = frameworkURL.appendingPathComponent(directory, isDirectory: true)
            guard directoryURLToStrip.isExistingDirectory else {
                return
            }
            try FileManager.default.removeItem(at: directoryURLToStrip)
        }
    }

    /// Signs a framework with the given codesigning identity.
    private static func codesign(_ frameworkURL: URL, _ expandedIdentity: String) -> CarthageResult<()> {
        let codesignTask = Task(
            "/usr/bin/xcrun",
            arguments: ["codesign", "--force", "--sign", expandedIdentity, "--preserve-metadata=identifier,entitlements", frameworkURL.path]
        )
        return codesignTask.launch()
            .mapError(CarthageError.taskError)
            .wait()
    }

    /// Determines which SDKs the given scheme builds for, by default.
    ///
    /// If an SDK is unrecognized or could not be determined, an error will be
    /// sent on the returned signal.
    private static func SDKsForScheme(_ scheme: Scheme, inProject project: ProjectLocator) -> CarthageResult<[SDK]> {
        return loadBuildSettings(with: BuildArguments(project: project, scheme: scheme))
            .flatMap { settingsArray -> CarthageResult<[SDK]> in
                guard let first = settingsArray.first else {
                    return .success([])
                }
                return first.buildSDKs
            }
    }
}

extension SignalProducer where Value: TaskEventType {
    /// Collect all TaskEvent success values and then send as a single array and complete.
    /// standard output and standard error data events are still sent as they are received.
    fileprivate func collectTaskEvents() -> SignalProducer<TaskEvent<[Value.T]>, Error> {
        return lift { $0.collectTaskEvents() }
    }
}

extension Signal where Value: TaskEventType {
    /// Collect all TaskEvent success values and then send as a single array and complete.
    /// standard output and standard error data events are still sent as they are received.
    fileprivate func collectTaskEvents() -> Signal<TaskEvent<[Value.T]>, Error> {
        var taskValues: [Value.T] = []

        return Signal<TaskEvent<[Value.T]>, Error> { observer, lifetime in
            lifetime += self.observe { event in
                switch event {
                case let .value(value):
                    if let taskValue = value.value {
                        taskValues.append(taskValue)
                    } else {
                        observer.send(value: value.map { [$0] })
                    }

                case .completed:
                    observer.send(value: .success(taskValues))
                    observer.sendCompleted()

                case let .failed(error):
                    observer.send(error: error)

                case .interrupted:
                    observer.sendInterrupted()
                }
            }
        }
    }
}
