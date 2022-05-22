import Foundation
import ArgumentParser

/// The subcommand for running an app from a package.
struct RunCommand: AsyncCommand {
  static var configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a package as an app."
  )

  /// Arguments in common with the bundle command.
  @OptionGroup
  var arguments: BundleArguments

  /// A file containing environment variables to pass to the app.
  @Option(
    name: [.customLong("env")],
    help: "A file containing environment variables to pass to the app.",
    transform: URL.init(fileURLWithPath:))
  var environmentFile: URL?

  @Option(
    name: [.customLong("simulator")],
    help: "A search term to identify the target simulator (e.g. 'iPhone 8').")
  var simulatorSearchTerm: String?

  /// If `true`, the building and bundling step is skipped.
  @Flag(
    name: .long,
    help: "Skips the building and bundling steps.")
  var skipBuild = false

  // MARK: Methods

  func wrappedRun() async throws {
    let packageDirectory = arguments.packageDirectory ?? URL(fileURLWithPath: ".")

    let outputDirectory = BundleCommand.getOutputDirectory(
      arguments.outputDirectory,
      packageDirectory: packageDirectory
    )

    let (appName, appConfiguration) = try BundleCommand.getAppConfiguration(
      arguments.appName,
      packageDirectory: packageDirectory,
      customFile: arguments.configurationFileOverride
    ).unwrap()

    // Get the device to run on
    let device: Device
    switch arguments.platform {
      case .macOS:
        device = .macOS
      case .iOS:
        device = .iOS
      case .iOSSimulator:
        if let searchTerm = simulatorSearchTerm {
          let simulators = try SimulatorManager.listAvailableSimulators(searchTerm: searchTerm).unwrap()

          guard let simulator = simulators.first else {
            log.error("Search term '\(searchTerm)' did not match any simulators")

            Output {
              Section("List available simulators") {
                // TODO: Implement simulator list command
                ExampleCommand("swift bundler simulators list")
              }
            }.show()

            Foundation.exit(1)
          }

          device = .iOSSimulator(id: simulator.id)
        } else {
          let allSimulators = try SimulatorManager.listAvailableSimulators().unwrap()

          // If an iOS simulator is booted, use that
          if allSimulators.contains(where: { $0.state == .booted }) {
            device = .iOSSimulator(id: "booted")
            break
          } else {
            log.error("To run on the iOS simulator, you must either use the '--simulator' option or have a valid simulator running already")
            Foundation.exit(1)
          }
        }
    }

    let bundleCommand = BundleCommand(arguments: _arguments, skipBuild: false, builtWithXcode: false)

    if !skipBuild {
      await bundleCommand.run()
    }

    try Runner.run(
      bundle: outputDirectory.appendingPathComponent("\(appName).app"),
      bundleIdentifier: appConfiguration.identifier,
      device: device,
      environmentFile: environmentFile
    ).unwrap()
  }
}
