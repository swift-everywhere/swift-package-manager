//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// The description of an individual module.
public struct TargetDescription: Hashable, Encodable, Sendable {
    @available(*, deprecated, renamed: "TargetKind")
    public typealias TargetType = TargetKind

    /// The target kind.
    public enum TargetKind: String, Hashable, Encodable, Sendable {
        case regular
        case executable
        case test
        case system
        case binary
        case plugin
        case `macro`
    }

    /// Represents a target's dependency on another entity.
    public enum Dependency: Hashable, Sendable {
        case target(name: String, condition: PackageConditionDescription?)
        case product(name: String, package: String?, moduleAliases: [String: String]? = nil, condition: PackageConditionDescription?)
        case byName(name: String, condition: PackageConditionDescription?)

        public var condition: PackageConditionDescription? {
            switch self {
            case .target(_, let condition):
                return condition
            case .product(_, _, _, let condition):
                return condition
            case .byName(_, let condition):
                return condition
            }
        }

        public var name: String {
            switch self {
            case .target(let name, _):
                return name
            case .product(let name, _, _, _):
                return name
            case .byName(let name, _):
                return name
            }
        }

        public var package: String? {
            switch self {
            case .product(_, let name?, _, _),
                  .byName(let name, _): // Note: byName can either refer to a product or target dependency
                return name
            default:
                return nil
            }
        }

        public static func target(name: String) -> Dependency {
            return .target(name: name, condition: nil)
        }

        public static func product(name: String, package: String? = nil, moduleAliases: [String: String]? = nil) -> Dependency {
            return .product(name: name, package: package, moduleAliases: moduleAliases, condition: nil)
        }
    }

    public struct Resource: Encodable, Hashable, Sendable {
        public enum Rule: Encodable, Hashable, Sendable {
            case process(localization: Localization?)
            case copy
            case embedInCode
        }

        public enum Localization: String, Encodable, Sendable {
            case `default`
            case base
        }

        /// The rule for the resource.
        public let rule: Rule

        /// The path of the resource.
        public let path: String

        public init(rule: Rule, path: String) {
            self.rule = rule
            self.path = path
        }
    }

    /// The name of the target.
    public let name: String

    /// If true, access to package declarations from other targets is allowed.
    /// APIs is not allowed from outside.
    public let packageAccess: Bool

    /// The custom path of the target.
    public let path: String?

    /// The url of the binary target artifact.
    public let url: String?

    /// The custom sources of the target.
    public let sources: [String]?

    /// The explicitly declared resources of the target.
    public let resources: [Resource]

    /// The exclude patterns.
    public let exclude: [String]

    // FIXME: Kill this.
    //
    /// Returns true if the target type is test.
    public var isTest: Bool {
        return type == .test
    }

    /// The declared target dependencies.
    public package(set) var dependencies: [Dependency]

    /// The custom public headers path.
    public let publicHeadersPath: String?

    /// The type of target.
    public let type: TargetKind

    /// The pkg-config name of a system library target.
    public let pkgConfig: String?

    /// The providers of a system library target.
    public let providers: [SystemPackageProviderDescription]?
    
    /// The declared capability for a package plugin target.
    public let pluginCapability: PluginCapability?
    
    /// Represents the declared capability of a package plugin.
    public enum PluginCapability: Hashable, Sendable {
        case buildTool
        case command(intent: PluginCommandIntent, permissions: [PluginPermission])
    }
    
    public enum PluginCommandIntent: Hashable, Codable, Sendable {
        case documentationGeneration
        case sourceCodeFormatting
        case custom(verb: String, description: String)
    }

    public enum PluginNetworkPermissionScope: Hashable, Codable, Sendable {
        case none
        case local(ports: [Int])
        case all(ports: [Int])
        case docker
        case unixDomainSocket

        public init?(_ scopeString: String, ports: [Int]) {
            switch scopeString {
            case "none": self = .none
            case "local": self = .local(ports: ports)
            case "all": self = .all(ports: ports)
            case "docker": self = .docker
            case "unix-socket": self = .unixDomainSocket
            default: return nil
            }
        }
    }

    public enum PluginPermission: Hashable, Codable, Sendable {
        case allowNetworkConnections(scope: PluginNetworkPermissionScope, reason: String)
        case writeToPackageDirectory(reason: String)
    }

    /// The target-specific build settings declared in this target.
    public let settings: [TargetBuildSettingDescription.Setting]

    /// The binary target checksum.
    public let checksum: String?
    
    /// The usages of package plugins by the target.
    public let pluginUsages: [PluginUsage]?

    /// Represents a target's usage of a plugin target or product.
    public enum PluginUsage: Hashable, Sendable {
        case plugin(name: String, package: String?)
    }

    public init(
        name: String,
        dependencies: [Dependency] = [],
        path: String? = nil,
        url: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource] = [],
        publicHeadersPath: String? = nil,
        type: TargetKind = .regular,
        packageAccess: Bool = true,
        pkgConfig: String? = nil,
        providers: [SystemPackageProviderDescription]? = nil,
        pluginCapability: PluginCapability? = nil,
        settings: [TargetBuildSettingDescription.Setting] = [],
        checksum: String? = nil,
        pluginUsages: [PluginUsage]? = nil
    ) throws {
        let targetType = String(describing: type)
        switch type {
        case .regular, .executable, .test:
            if url != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "url",
                value: url ?? "<nil>"
            ) }
            if pkgConfig != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pkgConfig",
                value: pkgConfig ?? "<nil>"
            ) }
            if providers != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "providers",
                value: String(describing: providers!)
            ) }
            if pluginCapability != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginCapability",
                value: String(describing: pluginCapability!)
            ) }
            if checksum != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "checksum",
                value: checksum ?? "<nil>"
            ) }
        case .system:
            if !dependencies.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "dependencies",
                value: String(describing: dependencies)
            ) }
            if !exclude.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "exclude",
                value: String(describing: exclude)
            ) }
            if sources != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "sources",
                value: String(describing: sources!)
            ) }
            if !resources.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "resources",
                value: String(describing: resources)
            ) }
            if publicHeadersPath != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "publicHeadersPath",
                value: publicHeadersPath ?? "<nil>"
            ) }
            if pluginCapability != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginCapability",
                value: String(describing: pluginCapability!)
            ) }
            if !settings.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "settings",
                value: String(describing: settings)
            ) }
            if checksum != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "checksum",
                value: checksum ?? "<nil>"
            ) }
            if pluginUsages != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginUsages",
                value: String(describing: pluginUsages!)
            ) }
        case .binary:
            if path == nil && url == nil { throw Error.binaryTargetRequiresEitherPathOrURL(targetName: name) }
            if !dependencies.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "dependencies",
                value: String(describing: dependencies)
            ) }
            if !exclude.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "exclude",
                value: String(describing: exclude)
            ) }
            if sources != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "sources",
                value: String(describing: sources!)
            ) }
            if !resources.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "resources",
                value: String(describing: resources)
            ) }
            if publicHeadersPath != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "publicHeadersPath",
                value: publicHeadersPath ?? "<nil>"
            ) }
            if pkgConfig != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pkgConfig",
                value: pkgConfig ?? "<nil>"
            ) }
            if providers != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "providers",
                value: String(describing: providers!)
            ) }
            if pluginCapability != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginCapability",
                value: String(describing: pluginCapability!)
            ) }
            if !settings.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "settings",
                value: String(describing: settings)
            ) }
            if pluginUsages != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginUsages",
                value: String(describing: pluginUsages!)
            ) }
        case .plugin:
            if pluginCapability == nil { throw Error.pluginTargetRequiresPluginCapability(targetName: name) }
            if url != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "url",
                value: url ?? "<nil>"
            ) }
            if !resources.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "resources",
                value: String(describing: resources)
            ) }
            if publicHeadersPath != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "publicHeadersPath",
                value: publicHeadersPath ?? "<nil>"
            ) }
            if pkgConfig != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pkgConfig",
                value: pkgConfig ?? "<nil>"
            ) }
            if providers != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "providers",
                value: String(describing: providers!)
            ) }
            if !settings.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "settings",
                value: String(describing: settings)
            ) }
            if pluginUsages != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginUsages",
                value: String(describing: pluginUsages!)
            ) }
        case .macro:
            if url != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "url",
                value: url ?? "<nil>"
            ) }
            if !resources.isEmpty { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "resources",
                value: String(describing: resources)
            ) }
            if publicHeadersPath != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "publicHeadersPath",
                value: publicHeadersPath ?? "<nil>"
            ) }
            if pkgConfig != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pkgConfig",
                value: pkgConfig ?? "<nil>"
            ) }
            if providers != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "providers",
                value: String(describing: providers!)
            ) }
            if pluginCapability != nil { throw Error.disallowedPropertyInTarget(
                targetName: name,
                targetType: targetType,
                propertyName: "pluginCapability",
                value: String(describing: pluginCapability!)
            ) }
        }

        self.name = name
        self.dependencies = dependencies
        self.path = path
        self.url = url
        self.publicHeadersPath = publicHeadersPath
        self.sources = sources
        self.exclude = exclude
        self.resources = resources
        self.type = type
        self.packageAccess = packageAccess
        self.pkgConfig = pkgConfig
        self.providers = providers
        self.pluginCapability = pluginCapability
        self.settings = settings
        self.checksum = checksum
        self.pluginUsages = pluginUsages
    }
}

extension TargetDescription.Dependency: Codable {
    private enum CodingKeys: String, CodingKey {
        case target, product, byName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .target(a1, a2):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .target)
            try unkeyedContainer.encode(a1)
            try unkeyedContainer.encode(a2)
        case let .product(a1, a2, a3, a4):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .product)
            try unkeyedContainer.encode(a1)
            try unkeyedContainer.encode(a2)
            try unkeyedContainer.encode(a3)
            try unkeyedContainer.encode(a4)
        case let .byName(a1, a2):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .byName)
            try unkeyedContainer.encode(a1)
            try unkeyedContainer.encode(a2)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .target:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(String.self)
            let a2 = try unkeyedValues.decodeIfPresent(PackageConditionDescription.self)
            self = .target(name: a1, condition: a2)
        case .product:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(String.self)
            let a2 = try unkeyedValues.decodeIfPresent(String.self)
            let a3 = try unkeyedValues.decode([String: String].self)
            let a4 = try unkeyedValues.decodeIfPresent(PackageConditionDescription.self)
            self = .product(name: a1, package: a2, moduleAliases: a3, condition: a4)
        case .byName:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(String.self)
            let a2 = try unkeyedValues.decodeIfPresent(PackageConditionDescription.self)
            self = .byName(name: a1, condition: a2)
        }
    }
}

extension TargetDescription.Dependency: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .byName(name: value, condition: nil)
    }
}

extension TargetDescription.PluginCapability: Codable {
    private enum CodingKeys: CodingKey {
        case buildTool, command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .buildTool:
            try container.encodeNil(forKey: .buildTool)
        case .command(let a1, let a2):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .command)
            try unkeyedContainer.encode(a1)
            try unkeyedContainer.encode(a2)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .buildTool:
            self = .buildTool
        case .command:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let a1 = try unkeyedValues.decode(TargetDescription.PluginCommandIntent.self)
            let a2 = try unkeyedValues.decode([TargetDescription.PluginPermission].self)
            self = .command(intent: a1, permissions: a2)
        }
    }
}

extension TargetDescription.PluginUsage: Codable {
    private enum CodingKeys: String, CodingKey {
        case plugin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .plugin(name, package):
            var unkeyedContainer = container.nestedUnkeyedContainer(forKey: .plugin)
            try unkeyedContainer.encode(name)
            try unkeyedContainer.encode(package)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = values.allKeys.first(where: values.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Did not find a matching key"))
        }
        switch key {
        case .plugin:
            var unkeyedValues = try values.nestedUnkeyedContainer(forKey: key)
            let name = try unkeyedValues.decode(String.self)
            let package = try unkeyedValues.decodeIfPresent(String.self)
            self = .plugin(name: name, package: package)
        }
    }
}

import protocol Foundation.LocalizedError

private enum Error: LocalizedError, Equatable {
    case binaryTargetRequiresEitherPathOrURL(targetName: String)
    case pluginTargetRequiresPluginCapability(targetName: String)
    case disallowedPropertyInTarget(targetName: String, targetType: String, propertyName: String, value: String)

    var errorDescription: String? {
        switch self {
        case .binaryTargetRequiresEitherPathOrURL(let targetName):
            "binary target '\(targetName)' must define either path or URL for its artifacts"
        case .pluginTargetRequiresPluginCapability(let targetName):
            "plugin target '\(targetName)' must define a plugin capability"
        case .disallowedPropertyInTarget(let targetName, let targetType, let propertyName, let value):
            "target '\(targetName)' is assigned a property '\(propertyName)' which is not accepted " +
            "for the \(targetType) target type. The current property value has " +
            "the following representation: \(value)."
        }
    }
}
