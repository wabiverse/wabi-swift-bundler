import Foundation
import Parsing
import StackOtterArgParser
import Version
import Yams

/// A utility for interacting with the Swift package manager and performing some other package
/// related operations.
enum SwiftPackageManager {
  /// The context for a build.
  struct BuildContext {
    /// The root directory of the package containing the product.
    var packageDirectory: URL
    /// The SwiftPM scratch directory in use.
    var scratchDirectory: URL
    /// The build configuration to use.
    var configuration: BuildConfiguration
    /// The set of architectures to build for.
    var architectures: [BuildArchitecture]
    /// The platform to build for.
    var platform: Platform
    /// The platform version to build for.
    var platformVersion: String?
    /// Additional arguments to be passed to SwiftPM.
    var additionalArguments: [String]
    /// Controls whether the hot reloading environment variables are added to
    /// the build command or not.
    var hotReloadingEnabled: Bool = false
  }

  /// Creates a new package using the given directory as the package's root directory.
  /// - Parameters:
  ///   - directory: The package's root directory (will be created if it doesn't exist).
  ///   - name: The name for the package.
  /// - Returns: If an error occurs, a failure is returned.
  static func createPackage(
    in directory: URL,
    name: String
  ) -> Result<Void, SwiftPackageManagerError> {
    // Create the package directory if it doesn't exist
    let directoryExists = FileManager.default.itemExists(at: directory, withType: .directory)
    return Result.success()
      .andThen(if: !directoryExists) { _ in
        FileManager.default.createDirectory(
          at: directory,
          onError: SwiftPackageManagerError.failedToCreatePackageDirectory
        )
      }
      .andThen { _ in
        // Run the init command
        let arguments = [
          "package", "init",
          "--type=executable",
          "--name=\(name)",
        ]

        let process = Process.create(
          "swift",
          arguments: arguments,
          directory: directory
        )
        process.setOutputPipe(Pipe())

        return process.runAndWait()
          .mapError { error in
            .failedToRunSwiftInit(
              command: "swift \(arguments.joined(separator: " "))",
              error
            )
          }
      }
      .andThen { _ in
        // Create the configuration file
        PackageConfiguration.createConfigurationFile(
          in: directory,
          app: name,
          product: name
        ).mapError { error in
          .failedToCreateConfigurationFile(error)
        }
      }
  }

  /// Builds the specified product of a Swift package.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - buildContext: The context to build in.
  /// - Returns: If an error occurs, returns a failure.
  static func build(
    product: String,
    buildContext: BuildContext
  ) -> Result<Void, SwiftPackageManagerError> {
    log.info("Starting \(buildContext.configuration.rawValue) build")

    return createBuildArguments(
      product: product,
      buildContext: buildContext
    ).andThen { arguments in

      let pipe = Pipe()
      let process: Process

      var xcbeautify: Process?
      let xcbeautifyCmd = Process.locate("xcbeautify")
      switch xcbeautifyCmd
      {
        case .success(let cmd):
          xcbeautify = Process.create(
            cmd,
            arguments: [
              "--disable-logging"
            ],
            directory: buildContext.packageDirectory,
            runSilentlyWhenNotVerbose: false
          )
        case .failure(_):
          #if os(macOS)
            let helpMsg = "brew install xcbeautify"
          #else
            let helpMsg = "mint install cpisciotta/xcbeautify"
          #endif
          log.warning("""
          xcbeautify was not found, for pretty build output please intall it with:\n
          \(helpMsg)
          """)
      }

      process = Process.create(
        "swift",
        arguments: arguments,
        directory: buildContext.packageDirectory,
        runSilentlyWhenNotVerbose: false
      )

      if buildContext.hotReloadingEnabled {
        process.addEnvironmentVariables([
          "SWIFT_BUNDLER_HOT_RELOADING": "1"
        ])
      }

      // pipe xcodebuild output to xcbeautify.
      if let xcbeautify = xcbeautify {
        process.standardOutput = pipe
        xcbeautify.standardInput = pipe
      }

      do {
        try xcbeautify?.run()
      } catch {
        log.warning("xcbeautify error: \(error)")
      }

      return process.runAndWait().mapError { error in
        .failedToRunSwiftBuild(
          command: "swift \(arguments.joined(separator: " "))",
          error
        )
      }
    }
  }

  /// Builds the specified executable product of a Swift package as a dynamic library.
  /// Used in hot reloading, should not be relied upon for producing production builds.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - buildContext: The context to build in.
  /// - Returns: If an error occurs, returns a failure.
  static func buildExecutableAsDylib(
    product: String,
    buildContext: BuildContext
  ) -> Result<URL, SwiftPackageManagerError> {
    #if os(macOS)
      // TODO: Package up 'build options' into a struct so that it can be passed around
      //   more easily
      let productsDirectory: URL
      switch SwiftPackageManager.getProductsDirectory(buildContext) {
        case let .success(value):
          productsDirectory = value
        case let .failure(error):
          return .failure(error)
      }
      let dylibFile = productsDirectory.appendingPathComponent("lib\(product).dylib")

      return build(
        product: product,
        buildContext: buildContext
      ).andThen { _ in
        let buildPlanFile = buildContext.scratchDirectory
          .appendingPathComponent("\(buildContext.configuration).yaml")
        let buildPlanString: String
        do {
          buildPlanString = try String(contentsOf: buildPlanFile)
        } catch {
          return .failure(.failedToReadBuildPlan(path: buildPlanFile, error))
        }

        let buildPlan: BuildPlan
        do {
          buildPlan = try YAMLDecoder().decode(BuildPlan.self, from: buildPlanString)
        } catch {
          return .failure(.failedToDecodeBuildPlan(error))
        }

        let commandName = "C.\(product)-\(buildContext.configuration).exe"
        guard
          let linkCommand = buildPlan.commands[commandName],
          linkCommand.tool == "shell",
          let commandExecutable = linkCommand.arguments?.first,
          let arguments = linkCommand.arguments?.dropFirst()
        else {
          return .failure(
            .failedToComputeLinkingCommand(
              details: "Couldn't find valid command for \(commandName)"
            )
          )
        }

        var modifiedArguments = Array(arguments)
        guard
          let index = modifiedArguments.firstIndex(of: "-o"),
          index < modifiedArguments.count - 1
        else {
          return .failure(
            .failedToComputeLinkingCommand(details: "Couldn't find '-o' argument to replace")
          )
        }

        modifiedArguments.remove(at: index)
        modifiedArguments.remove(at: index)
        modifiedArguments.append(contentsOf: [
          "-o",
          dylibFile.path,
          "-Xcc",
          "-dynamiclib",
        ])

        let process = Process.create(
          commandExecutable,
          arguments: modifiedArguments,
          directory: buildContext.packageDirectory,
          runSilentlyWhenNotVerbose: false
        )

        return process.runAndWait()
          .map { _ in dylibFile }
          .mapError { error in
            // TODO: Make a more robust way of converting commands to strings for display (keeping
            //   correctness in mind in case users want to copy-paste commands from errors).
            return .failedToRunLinkingCommand(
              command: ([commandExecutable]
                + modifiedArguments.map { argument in
                  if argument.contains(" ") {
                    return "\"\(argument)\""
                  } else {
                    return argument
                  }
                }).joined(separator: " "),
              error
            )
          }
      }
    #else
      fatalError("buildExecutableAsDylib not implemented for current platform")
      #warning("buildExecutableAsDylib not implemented for current platform")
    #endif
  }

  /// Creates the arguments for the Swift build command.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - buildContext: The context to build in.
  /// - Returns: The build arguments, or a failure if an error occurs.
  static func createBuildArguments(
    product: String?,
    buildContext: BuildContext
  ) -> Result<[String], SwiftPackageManagerError> {
    let platformArguments: [String]
    switch buildContext.platform {
      case .iOS, .visionOS, .tvOS, .iOSSimulator, .visionOSSimulator, .tvOSSimulator:
        let sdkPath: String
        switch getLatestSDKPath(for: buildContext.platform) {
          case .success(let path):
            sdkPath = path
          case .failure(let error):
            return .failure(error)
        }

        guard let platformVersion = buildContext.platformVersion else {
          return .failure(.missingDarwinPlatformVersion(buildContext.platform))
        }
        let hostArchitecture = BuildArchitecture.current

        let targetTriple: LLVMTargetTriple
        switch buildContext.platform {
          case .iOS:
            targetTriple = .apple(.arm64, .iOS(platformVersion))
          case .visionOS:
            targetTriple = .apple(.arm64, .visionOS(platformVersion))
          case .tvOS:
            targetTriple = .apple(.arm64, .tvOS(platformVersion))
          case .iOSSimulator:
            targetTriple = .apple(hostArchitecture, .iOS(platformVersion), .simulator)
          case .visionOSSimulator:
            targetTriple = .apple(hostArchitecture, .visionOS(platformVersion), .simulator)
          case .tvOSSimulator:
            targetTriple = .apple(hostArchitecture, .tvOS(platformVersion), .simulator)
          default:
            fatalError("Unreachable (supposedly)")
        }

        platformArguments =
          [
            "-sdk", sdkPath,
            "-target", targetTriple.description,
          ].flatMap { ["-Xswiftc", $0] }
          + [
            "--target=\(targetTriple)",
            "-isysroot", sdkPath,
          ].flatMap { ["-Xcc", $0] }
      case .macOS, .linux:
        platformArguments = []
    }

    let architectureArguments = buildContext.architectures.flatMap { architecture in
      ["--arch", architecture.argument(for: buildContext.platform)]
    }

    let productArguments = product.map { ["--product", $0] } ?? []
    let scratchDirectoryArguments = ["--scratch-path", buildContext.scratchDirectory.path]
    let arguments =
      [
        "build",
        "-c", buildContext.configuration.rawValue,
      ]
      + productArguments
      + architectureArguments
      + platformArguments
      + scratchDirectoryArguments
      + buildContext.additionalArguments

    return .success(arguments)
  }

  /// Gets the path to the latest SDK for a given platform.
  /// - Parameter platform: The platform to get the SDK path for.
  /// - Returns: The SDK's path, or a failure if an error occurs.
  static func getLatestSDKPath(for platform: Platform) -> Result<String, SwiftPackageManagerError> {
    return Process.create(
      "/usr/bin/xcrun",
      arguments: [
        "--sdk", platform.sdkName,
        "--show-sdk-path",
      ]
    ).getOutput().map { output in
      return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }.mapError { error in
      return .failedToGetLatestSDKPath(platform, error)
    }
  }

  /// Gets the version of the current Swift installation.
  /// - Returns: The swift version, or a failure if an error occurs.
  static func getSwiftVersion() -> Result<Version, SwiftPackageManagerError> {
    let process = Process.create(
      "swift",
      arguments: ["--version"])

    return process.getOutput()
      .mapError(SwiftPackageManagerError.failedToGetSwiftVersion)
      .andThen { output in
        // The first two examples are for release versions of Swift (the first on macOS, the second on Linux).
        // The next two examples are for snapshot versions of Swift (the first on macOS, the second on Linux).
        // Sample: "swift-driver version: 1.45.2 Apple Swift version 5.6 (swiftlang-5.6.0.323.62 clang-1316.0.20.8)"
        //     OR: "swift-driver version: 1.45.2 Swift version 5.6 (swiftlang-5.6.0.323.62 clang-1316.0.20.8)"
        //     OR: "Apple Swift version 5.9-dev (LLVM 464b04eb9b157e3, Swift 7203d52cb1e074d)"
        //     OR: "Swift version 5.9-dev (LLVM 464b04eb9b157e3, Swift 7203d52cb1e074d)"
        let parser = OneOf {
          Parse {
            "swift-driver version"
            Prefix { $0 != "(" }
            "(swiftlang-"
            Parse({ Version(major: $0, minor: $1, patch: $2) }) {
              Int.parser(of: Substring.self, radix: 10)
              "."
              Int.parser(of: Substring.self, radix: 10)
              "."
              Int.parser(of: Substring.self, radix: 10)
            }
            Rest<Substring>()
          }.map { (_: Substring, version: Version, _: Substring) in
            version
          }

          Parse {
            Optionally {
              "Apple "
            }
            "Swift version "
            Parse({ Version(major: $0, minor: $1, patch: 0) }) {
              Int.parser(of: Substring.self, radix: 10)
              "."
              Int.parser(of: Substring.self, radix: 10)
            }
            Rest<Substring>()
          }.map { (_: Void?, version: Version, _: Substring) in
            version
          }
        }

        return Result {
          try parser.parse(output)
        }.mapError { error in
          .invalidSwiftVersionOutput(output, error)
        }
      }
  }

  /// Gets the default products directory for builds occuring within the given
  /// context.
  /// - Parameters:
  ///   - buildContext: The context the build is occuring within.
  /// - Returns: The default products directory. If `swift build --show-bin-path ... # extra args`
  ///   fails, a failure is returned.
  static func getProductsDirectory(
    _ buildContext: BuildContext
  ) -> Result<URL, SwiftPackageManagerError> {
    return createBuildArguments(
      product: nil,
      buildContext: buildContext
    ).andThen { arguments in
      let process = Process.create(
        "swift",
        arguments: arguments + ["--show-bin-path"],
        directory: buildContext.packageDirectory
      )

      return process.getOutput().map { output in
        URL(fileURLWithPath: output.trimmingCharacters(in: .newlines))
      }.mapError { error in
        .failedToGetProductsDirectory(command: "swift " + process.argumentsString, error)
      }
    }
  }

  /// Loads a root package manifest from a package's root directory.
  /// - Parameter packageDirectory: The package's root directory.
  /// - Returns: The loaded manifest, or a failure if an error occurs.
  static func loadPackageManifest(
    from packageDirectory: URL
  ) async -> Result<PackageManifest, SwiftPackageManagerError> {
    // We used to use the SwiftPackageManager library to load package manifests,
    // but that caused issues when the library version didn't match the user's
    // installed Swift version and was very fiddly to fix. It was easier to just
    // hand roll a custom solution that we can update in the future to maintain
    // backwards compatability.
    //
    // Overview of loading a manifest manually:
    // - Compile and link manifest with Swift driver
    // - Run the resulting executable with `-fileno 1` as its args
    // - Parse the JSON that the executable outputs to stdout

    let manifestPath = packageDirectory.appendingPathComponent("Package.swift").path
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let uuid = UUID().uuidString
    let temporaryExecutableFile =
      temporaryDirectory
      .appendingPathComponent("\(uuid)-PackageManifest").path

    let targetInfo: SwiftTargetInfo
    switch self.getTargetInfo() {
      case .success(let info):
        targetInfo = info
      case .failure(let error):
        return .failure(error)
    }

    let manifestAPIDirectory = targetInfo.paths.runtimeResourcePath
      .appendingPathComponent("pm/ManifestAPI")

    var librariesPaths: [String] = []
    librariesPaths += targetInfo.paths.runtimeLibraryPaths.map(\.path)
    librariesPaths += [manifestAPIDirectory.path]

    var additionalSwiftArguments: [String] = []
    #if os(macOS)
      switch self.getLatestSDKPath(for: .macOS) {
        case .success(let path):
          librariesPaths += [path + "/usr/lib/swift"]
          additionalSwiftArguments += ["-sdk", path]
        case .failure(let error):
          return .failure(error)
      }
    #endif

    let toolsVersionProcess = Process.create(
      "swift",
      arguments: ["package", "tools-version"],
      directory: packageDirectory
    )
    let toolsVersion: String
    let swiftMajorVersion: String
    switch toolsVersionProcess.getOutput() {
      case .success(let output):
        toolsVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
        swiftMajorVersion = String(toolsVersion.first!)
      case .failure(let error):
        return .failure(.failedToParsePackageManifestToolsVersion(error))
    }

    // Compile to object file
    let swiftArguments =
      [
        manifestPath,
        "-I", manifestAPIDirectory.path,
        "-Xlinker", "-rpath", "-Xlinker", manifestAPIDirectory.path,
        "-lPackageDescription",
        "-swift-version", swiftMajorVersion, "-package-description-version", toolsVersion,
        "-disable-implicit-concurrency-module-import",
        "-disable-implicit-string-processing-module-import",
        "-o", temporaryExecutableFile,
      ]
      + librariesPaths.flatMap { ["-L", $0] }
      + additionalSwiftArguments

    let swiftProcess = Process.create("swiftc", arguments: swiftArguments)
    if case let .failure(error) = swiftProcess.runAndWait() {
      return .failure(.failedToCompilePackageManifest(error))
    }

    // Execute compiled manifest
    let process = Process.create(temporaryExecutableFile, arguments: ["-fileno", "1"])
    let json: String
    switch process.getOutput() {
      case .success(let output):
        json = output
      case .failure(let error):
        return .failure(.failedToExecutePackageManifest(error))
    }

    // Parse manifest output
    guard let jsonData = json.data(using: .utf8) else {
      return .failure(.failedToParsePackageManifestOutput(json: json, nil))
    }

    do {
      return .success(
        try JSONDecoder().decode(PackageManifest.self, from: jsonData)
      )
    } catch {
      return .failure(.failedToParsePackageManifestOutput(json: json, error))
    }
  }

  static func getTargetInfo() -> Result<SwiftTargetInfo, SwiftPackageManagerError> {
    // TODO: This could be a nice easy one to unit test
    let process = Process.create(
      "swift",
      arguments: ["-print-target-info"]
    )

    return process.getOutput().mapError { error in
      .failedToGetTargetInfo(command: "swift " + process.argumentsString, error)
    }.andThen { output in
      guard let data = output.data(using: .utf8) else {
        return .failure(.failedToParseTargetInfo(json: output, nil))
      }

      return JSONDecoder().decode(SwiftTargetInfo.self, from: data)
        .mapError { error in
          .failedToParseTargetInfo(json: output, error)
        }
    }
  }
}
