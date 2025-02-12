import Foundation
import Parsing
import StackOtterArgParser
import Version
import Yams

/// A utility for interacting with xcodebuild.
enum Xcodebuild {
  /// Builds the specified product using a Swift package target as an xcodebuild scheme.
  /// - Parameters:
  ///   - product: The product to build.
  ///   - buildContext: The context to build in.
  /// - Returns: If an error occurs, returns a failure.
  static func build(
    product: String,
    buildContext: SwiftPackageManager.BuildContext
  ) -> Result<Void, XcodebuildError> {
    guard let applePlatform = buildContext.platform.asApplePlatform else {
      return .failure(.unsupportedPlatform(buildContext.platform))
    }

    let scheme =
      buildContext.packageDirectory
      / ".swiftpm/xcode/xcshareddata/xcschemes/\(product).xcscheme"

    let cleanup: (() -> Void)?
    if scheme.exists() {
      let temporaryScheme = FileManager.default.temporaryDirectory / "\(UUID().uuidString).xcscheme"

      do {
        try FileManager.default.moveItem(at: scheme, to: temporaryScheme)
      } catch {
        return .failure(
          .failedToMoveInterferingScheme(
            scheme,
            destination: temporaryScheme,
            error
          )
        )
      }

      cleanup = {
        do {
          try FileManager.default.moveItem(at: temporaryScheme, to: scheme)
        } catch {
          let relativePath = scheme.path(relativeTo: URL(fileURLWithPath: "."))
          log.warning(
            """
            Failed to restore xcscheme to \(relativePath). You may need to \
            re-run 'swift bundler generate-xcode-support' if you use \
            Xcode to build your project.
            """
          )
        }
      }
    } else {
      cleanup = nil
    }

    defer {
      cleanup?()
    }

    let pipe = Pipe()
    let process: Process

    let useXCBeautify = ProcessInfo.processInfo.bundlerEnvironment.useXCBeautify
    let xcbeautifyProcess: Process?
    if useXCBeautify {
      let xcbeautifyCommand = Process.locate("xcbeautify")
      switch xcbeautifyCommand {
        case .success(let command):
          xcbeautifyProcess = Process.create(
            command,
            arguments: [
              "--disable-logging",
              //"--preserve-unbeautified",
            ],
            directory: buildContext.packageDirectory,
            runSilentlyWhenNotVerbose: false
          )
        case .failure(_):
          xcbeautifyProcess = nil
      }
    } else {
      xcbeautifyProcess = nil
    }

    let archString = buildContext.architectures
      .map(\.rawValue)
      .joined(separator: "_")

    let destinationArguments: [String]

    if buildContext.platform != .macOS {
      // retrieving simulators for the -destination argument is only relevant for non-macOS platforms.
      guard
        let simulators = try? SimulatorManager.listAvailableOSSimulators(for: buildContext.platform)
          .unwrap()
      else {
        return .failure(
          .failedToRunXcodebuild(
            command: "xcodebuild: could not retrieve list of available destinations.",
            .nonZeroExitStatus(-1)
          )
        )
      }

      var destinations: [XcodebuildDestination] = []
      for os in simulators.map(\.OS) {
        for simulators in simulators.filter({ $0.OS == os }).map(\.simulators) {
          for simulator in simulators {
            destinations.append(
              XcodebuildDestination(
                name: simulator.name,
                platform: buildContext.platform.name.replacingOccurrences(
                  of: "Simulator", with: " Simulator"),
                OS: os
              )
            )
          }
        }
      }

      // ----- some filters -----

      // we only care about matching the specifed platform name.
      let forPlatform: (XcodebuildDestination) -> Bool = { simulator in
        return simulator.platform.contains(
          buildContext.platform.name.replacingOccurrences(of: "Simulator", with: " Simulator"))
      }
      // we prefer to ignore iPhone SE models.
      let removeBlacklisted: (XcodebuildDestination) -> Bool = { simulator in
        return !simulator.name.contains("iPhone SE")
      }

      // ------------------------

      // 1. sort from highest to lowest semantic versions...
      destinations.sort { OSVersion($0.OS) > OSVersion($1.OS) }

      var destination: XcodebuildDestination? = nil
      for dest in destinations.filter({ forPlatform($0) && removeBlacklisted($0) }) {
        // 2. because we grab the latest semantic version available here.
        destination = dest
        break
      }

      guard let buildDest = destination else {
        return .failure(
          .failedToRunXcodebuild(
            command: "xcodebuild: could not retrieve a valid build destination.",
            .nonZeroExitStatus(-1)
          ))
      }

      destinationArguments = [
        "-destination",
        "platform=\(buildDest.platform),OS=\(buildDest.OS),name=\(buildDest.name)",
      ]
    } else {
      destinationArguments = [
        "-destination",
        "platform=macOS,arch=\(archString)",
      ]
    }

    process = Process.create(
      "xcodebuild",
      arguments: [
        "-scheme", product,
        "-configuration", buildContext.configuration.rawValue.capitalized,
        "-usePackageSupportBuiltinSCM",
        "-skipMacroValidation",
        "-derivedDataPath",
        buildContext.packageDirectory.appendingPathComponent(
          ".build/\(archString)-apple-\(buildContext.platform.sdkName)"
        ).path,
      ] + destinationArguments + buildContext.additionalArguments,
      directory: buildContext.packageDirectory,
      runSilentlyWhenNotVerbose: false
    )

    if buildContext.hotReloadingEnabled {
      process.addEnvironmentVariables([
        "SWIFT_BUNDLER_HOT_RELOADING": "1"
      ])
    }

    // pipe xcodebuild output to xcbeautify.
    if let xcbeautifyProcess = xcbeautifyProcess {
      process.standardOutput = pipe
      xcbeautifyProcess.standardInput = pipe

      do {
        try xcbeautifyProcess.run()
      } catch {
        log.warning("xcbeautify error: \(error)")
      }
    }

    return process.runAndWait().mapError { error in
      return .failedToRunXcodebuild(
        command: "Failed to run xcodebuild.",
        error
      )
    }
  }

  /// Whether or not the bundle command utilizes xcodebuild instead of swiftpm.
  /// - Parameters:
  ///   - command: The subcommand for creating app bundles for a package.
  ///   - resolvedPlatform: The resolved target platform.
  /// - Returns: Whether or not xcodebuild is invoked instead of swiftpm.
  static func isUsingXcodebuild(
    for command: BundleCommand,
    resolvedPlatform: Platform
  ) -> Bool {
    var forceUsingXcodebuild = command.arguments.xcodebuild
    // For non-macOS Apple platforms (e.g. iOS) we default to using the
    // xcodebuild builder instead of SwiftPM because SwiftPM doesn't
    // properly support cross-compiling to other Apple platforms from
    // macOS (and the workaround Swift Bundler uses to do so breaks down
    // when the package uses macros or has conditional dependencies in
    // its Package.swift).
    let platformBreaksWithoutXcodebuild =
      resolvedPlatform.isApplePlatform
      && resolvedPlatform != .macOS
    if forceUsingXcodebuild
      || platformBreaksWithoutXcodebuild
    {
      forceUsingXcodebuild = true
    }

    // Allows the '--no-xcodebuild' flag to be passed in, to override whether
    // or not the swiftpm-based build system is used, even for embedded apple
    // platforms (ex. visionOS, iOS, tvOS, watchOS).
    return command.arguments.noXcodebuild ? false : forceUsingXcodebuild
  }
}
