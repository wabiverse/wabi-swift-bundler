import Foundation
import Parsing
import Version

struct ProjectConfiguration: Codable {
  /// The name of the default project generated by Swift Bundler.
  static let defaultProjectName = "default"

  var source: Source
  var revision: String?

  var builder: Builder
  var products: [String: Product]

  enum Error: LocalizedError {
    case invalidGitURL(String)

    var errorDescription: String? {
      switch self {
        case .invalidGitURL(let url):
          return "'\(url)' is not a valid URL"
      }
    }
  }

  struct Flat {
    var source: Source.Flat
    var builder: Builder.Flat
    var products: [String: Product]
  }

  struct Builder: Codable {
    var name: String
    var type: BuilderType
    var apiSource: Source?
    var api: APIRequirement?

    enum CodingKeys: String, CodingKey {
      case name
      case type
      case apiSource = "api_source"
      case api = "api"
    }

    struct Flat {
      var name: String
      var type: BuilderType
      var api: Source.FlatWithDefaultRepository
    }

    enum BuilderType: String, Codable {
      case wholeProject
    }
  }

  enum Source: Codable {
    case git(URL)
    case local(String)

    enum Flat {
      case local(_ path: String)
      case git(URL, requirement: APIRequirement)
    }

    /// A flattened version of source for usecases where there's a sensible
    /// default git repository (e.g. the stackotter/swift-bundler repository
    /// is the default if no builder API source is explicitly provided).
    enum FlatWithDefaultRepository {
      case local(_ path: String)
      case git(URL?, requirement: APIRequirement)

      func normalized(usingDefault defaultGitURL: URL) -> Flat {
        switch self {
          case .local(let path):
            return .local(path)
          case .git(let url, let requirement):
            return .git(url ?? defaultGitURL, requirement: requirement)
        }
      }
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let parser = OneOf {
        Parse {
          "git("
          PrefixUpTo(")")
          ")"
        }
        .map { (url: Substring) -> Result<Self, Error> in
          guard let url = URL(string: String(url)) else {
            return .failure(Error.invalidGitURL(String(url)))
          }
          return .success(Self.git(url))
        }

        Parse {
          "local("
          PrefixUpTo(")")
          ")"
        }.map { path in
          Result<_, Error>.success(Self.local(String(path)))
        }
      }
      self = try parser.parse(value).unwrap()
    }

    func encode(to encoder: any Encoder) throws {
      let value: String
      switch self {
        case .git(let url):
          value = "git(\(url.absoluteString))"
        case .local(let path):
          value = "local(\(path))"
      }
      var container = encoder.singleValueContainer()
      try container.encode(value)
    }
  }

  enum APIRequirement: Codable {
    case revision(String)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let parser = OneOf {
        Parse {
          "revision("
          PrefixUpTo(")")
          ")"
        }.map { revision in
          APIRequirement.revision(String(revision))
        }
      }
      self = try parser.parse(value)
    }

    func encode(to encoder: any Encoder) throws {
      let value: String
      switch self {
        case .revision(let revision):
          value = "revision(\(revision))"
      }
      var container = encoder.singleValueContainer()
      try container.encode(value)
    }
  }

  struct Product: Codable {
    var type: ProductType
    var outputDirectory: String?

    enum CodingKeys: String, CodingKey {
      case type
      case outputDirectory = "output_directory"
    }

    enum ProductType: String, Codable {
      case dynamicLibrary
      case staticLibrary
      case executable
    }

    func path(whenNamed name: String, platform: Platform) -> String {
      let baseName =
        switch type {
          case .dynamicLibrary, .staticLibrary:
            // Uses a switch statement so that alarms are raised when Windows gets added
            switch platform {
              case .linux, .macOS, .iOS, .iOSSimulator, .tvOS, .tvOSSimulator, .visionOS,
                .visionOSSimulator:
                "lib\(name)"
            }
          case .executable:
            name
        }
      let fileExtension =
        switch type {
          case .dynamicLibrary:
            switch platform {
              case .linux:
                ".so"
              case .macOS, .iOS, .iOSSimulator, .tvOS, .tvOSSimulator, .visionOS,
                .visionOSSimulator:
                ".dylib"
            }
          case .staticLibrary:
            ".a"
          case .executable:
            ""
        }
      let fileName = "\(baseName)\(fileExtension)"
      if let outputDirectory = outputDirectory {
        return "\(outputDirectory)/\(fileName)"
      } else {
        return fileName
      }
    }
  }
}