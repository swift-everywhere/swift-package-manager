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

import Foundation
import PackageModel

import struct Basics.AbsolutePath
import protocol Basics.FileSystem
import struct Basics.SourceControlURL
import struct Basics.InternalError
import struct Basics.RelativePath

import enum TSCBasic.PathValidationError
import struct TSCBasic.RegEx
import struct TSCBasic.StringError

import struct TSCUtility.Version

enum ManifestJSONParser {
    struct Input: Codable {
        let package: Serialization.Package
        let errors: [String]
    }

    struct VersionedInput: Codable {
        let version: Int
    }

    struct Result {
        var name: String
        var defaultLocalization: String?
        var platforms: [PlatformDescription] = []
        var targets: [TargetDescription] = []
        var pkgConfig: String?
        var swiftLanguageVersions: [SwiftLanguageVersion]?
        var dependencies: [PackageDependency] = []
        var providers: [SystemPackageProviderDescription]?
        var products: [ProductDescription] = []
        var traits: Set<TraitDescription> = []
        var cxxLanguageStandard: String?
        var cLanguageStandard: String?
    }

    static func parse(
        v4 jsonString: String,
        toolsVersion: ToolsVersion,
        packageKind: PackageReference.Kind,
        packagePath: AbsolutePath,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem
    ) throws -> ManifestJSONParser.Result {
        let decoder = JSONDecoder.makeWithDefaults()

        // Validate the version first to detect use of a mismatched PD library.
        let versionedInput: VersionedInput
        do {
            versionedInput = try decoder.decode(VersionedInput.self, from: jsonString)
        } catch {
            // If we cannot even decode the version, assume that a pre-5.9 PD library is being used which emits an incompatible JSON format.
            throw ManifestParseError.unsupportedVersion(version: 1, underlyingError: "\(error.interpolationDescription)")
        }
        guard versionedInput.version == 2 else {
            throw ManifestParseError.unsupportedVersion(version: versionedInput.version)
        }

        let input = try decoder.decode(Input.self, from: jsonString)

        guard input.errors.isEmpty else {
            throw ManifestParseError.runtimeManifestErrors(input.errors)
        }

        var packagePath = packagePath
        switch packageKind {
        case .localSourceControl(let _packagePath):
            // we have a more accurate path than the virtual one
            packagePath = _packagePath
        case .root(let _packagePath), .fileSystem(let _packagePath):
            // we dont have a more accurate path, and they should be the same
            // asserting (debug only) to make sure refactoring is correct 11/2023
            assert(packagePath == _packagePath, "expecting package path '\(packagePath)' to be the same as '\(_packagePath)'")
            break
        case .remoteSourceControl, .registry:
            // we dont have a more accurate path
            break
        }

        let dependencies = try input.package.dependencies.map {
            try Self.parseDependency(
                dependency: $0,
                toolsVersion: toolsVersion,
                parentPackagePath: packagePath,
                identityResolver: identityResolver,
                dependencyMapper: dependencyMapper,
                fileSystem: fileSystem
            )
        }

        return Result(
            name: input.package.name,
            defaultLocalization: input.package.defaultLocalization?.tag,
            platforms: try input.package.platforms.map { try Self.parsePlatforms($0) } ?? [],
            targets: try input.package.targets.map { try Self.parseTarget(target: $0, identityResolver: identityResolver) },
            pkgConfig: input.package.pkgConfig,
            swiftLanguageVersions: try input.package.swiftLanguageVersions.map { try Self.parseSwiftLanguageVersions($0) },
            dependencies: dependencies,
            providers: input.package.providers?.map { .init($0) },
            products: try input.package.products.map { try .init($0) },
            traits: Set(input.package.traits?.map { TraitDescription($0) } ?? []),
            cxxLanguageStandard: input.package.cxxLanguageStandard?.rawValue,
            cLanguageStandard: input.package.cLanguageStandard?.rawValue
        )
    }

    private static func parsePlatforms(_ declaredPlatforms: [Serialization.SupportedPlatform]) throws -> [PlatformDescription] {
        // Empty list is not supported.
        if declaredPlatforms.isEmpty {
            throw ManifestParseError.runtimeManifestErrors(["supported platforms can't be empty"])
        }

        var platforms: [PlatformDescription] = []

        for platform in declaredPlatforms {
            let description = PlatformDescription(platform)

            // Check for duplicates.
            if platforms.map({ $0.platformName }).contains(description.platformName) {
                // FIXME: We need to emit the API name and not the internal platform name.
                throw ManifestParseError.runtimeManifestErrors(["found multiple declaration for the platform: \(description.platformName)"])
            }

            platforms.append(description)
        }

        return platforms
    }

    private static func parseSwiftLanguageVersions(_ versions: [Serialization.SwiftVersion]) throws -> [SwiftLanguageVersion] {
        return try versions.map {
            let languageVersionString: String
            switch $0 {
            case .v3: languageVersionString = "3"
            case .v4: languageVersionString = "4"
            case .v4_2: languageVersionString = "4.2"
            case .v5: languageVersionString = "5"
            case .v6: languageVersionString = "6"
            case .version(let version): languageVersionString = version
            }
            guard let languageVersion = SwiftLanguageVersion(string: languageVersionString) else {
                throw ManifestParseError.runtimeManifestErrors(["invalid Swift language version: \(languageVersionString)"])
            }
            return languageVersion
        }
    }

    private static func parseDependency(
        dependency: Serialization.PackageDependency,
        toolsVersion: ToolsVersion,
        parentPackagePath: AbsolutePath,
        identityResolver: IdentityResolver,
        dependencyMapper: DependencyMapper,
        fileSystem: FileSystem
    ) throws -> PackageDependency {
        do {
            return try dependencyMapper.mappedDependency(
                MappablePackageDependency(dependency, parentPackagePath: parentPackagePath),
                fileSystem: fileSystem
            )
        } catch let error as TSCBasic.PathValidationError {
            if case .fileSystem(_, let path) = dependency.kind {
                throw ManifestParseError.invalidManifestFormat("'\(path)' is not a valid path for path-based dependencies; use relative or absolute path instead.", diagnosticFile: nil, compilerCommandLine: nil)
            } else {
                throw error
            }
        } catch {
            throw ManifestParseError.invalidManifestFormat("\(error.interpolationDescription)", diagnosticFile: nil, compilerCommandLine: nil)
        }
    }

    private static func parseTarget(
        target: Serialization.Target,
        identityResolver: IdentityResolver
    ) throws -> TargetDescription {
        let providers = target.providers?.map { SystemPackageProviderDescription($0) }
        let pluginCapability = target.pluginCapability.map { TargetDescription.PluginCapability($0) }
        let dependencies = try target.dependencies.map { try TargetDescription.Dependency($0, identityResolver: identityResolver) }

        try target.sources?.forEach{ _ = try RelativePath(validating: $0) }
        try target.exclude.forEach{ _ = try RelativePath(validating: $0) }

        let pluginUsages = target.pluginUsages?.map { TargetDescription.PluginUsage.init($0) }

        return try TargetDescription(
            name: target.name,
            dependencies: dependencies,
            path: target.path,
            url: target.url,
            exclude: target.exclude,
            sources: target.sources,
            resources: try Self.parseResources(target.resources),
            publicHeadersPath: target.publicHeadersPath,
            type: .init(target.type),
            packageAccess: target.packageAccess,
            pkgConfig: target.pkgConfig,
            providers: providers,
            pluginCapability: pluginCapability,
            settings: try Self.parseBuildSettings(target),
            checksum: target.checksum,
            pluginUsages: pluginUsages
        )
    }

    private static func parseResources(_ resources: [Serialization.Resource]?) throws -> [TargetDescription.Resource] {
        return try resources?.map {
            let path = try RelativePath(validating: $0.path)
            switch $0.rule {
            case "process":
                let localization = $0.localization.map({ TargetDescription.Resource.Localization(rawValue: $0.rawValue)! })
                return .init(rule: .process(localization: localization), path: path.pathString)
            case "copy":
                return .init(rule: .copy, path: path.pathString)
            case "embedInCode":
                return .init(rule: .embedInCode, path: path.pathString)
            default:
                throw InternalError("invalid resource rule \($0.rule)")
            }
        } ?? []
    }

    private static func parseBuildSettings(_ target: Serialization.Target) throws -> [TargetBuildSettingDescription.Setting] {
        var settings: [TargetBuildSettingDescription.Setting] = []
        try target.cSettings?.forEach {
            settings.append(try .init($0))
        }
        try target.cxxSettings?.forEach {
            settings.append(try .init($0))
        }
        try target.swiftSettings?.forEach {
            settings.append(try .init($0))
        }
        try target.linkerSettings?.forEach {
            settings.append(try .init($0))
        }
        return settings
    }

    /// Looks for Xcode-style build setting macros "$()".
    fileprivate static let invalidValueRegex = try! RegEx(pattern: #"(\$\(.*?\))"#)
}

extension SystemPackageProviderDescription {
    init(_ provider: Serialization.SystemPackageProvider) {
        switch provider {
        case .brew(let values):
            self = .brew(values)
        case .apt(let values):
            self = .apt(values)
        case .yum(let values):
            self = .yum(values)
        case .nuget(let values):
            self = .nuget(values)
        }
    }
}

extension PackageDependency.SourceControl.Requirement {
    init(_ requirement: Serialization.PackageDependency.SourceControlRequirement) {
        switch requirement {
        case .exact(let version):
            self = .exact(.init(version))
        case .range(let lowerBound, let upperBound):
            let lower: TSCUtility.Version = .init(lowerBound)
            let upper: TSCUtility.Version = .init(upperBound)
            self = .range(lower..<upper)
        case .revision(let revision):
            self = .revision(revision)
        case .branch(let branch):
            self = .branch(branch)
        }
    }
}

extension PackageDependency.Registry.Requirement {
    init(_ requirement: Serialization.PackageDependency.RegistryRequirement) {
        switch requirement {
        case .exact(let version):
            self = .exact(.init(version))
        case .range(let lowerBound, let upperBound):
            let lower: TSCUtility.Version = .init(lowerBound)
            let upper: TSCUtility.Version = .init(upperBound)
            self = .range(lower..<upper)
        }
    }
}

#if ENABLE_APPLE_PRODUCT_TYPES
extension ProductSetting {
    init(_ setting: Serialization.ProductSetting) {
        switch setting {
        case .bundleIdentifier(let value):
            self = .bundleIdentifier(value)
        case .teamIdentifier(let value):
            self = .teamIdentifier(value)
        case .displayVersion(let value):
            self = .displayVersion(value)
        case .bundleVersion(let value):
            self = .bundleVersion(value)
        case .iOSAppInfo(let appInfo):
            self = .iOSAppInfo(.init(appInfo))
        }
    }
}

extension ProductSetting.IOSAppInfo {
    init(_ appInfo: Serialization.ProductSetting.IOSAppInfo) {
        self.init(
            appIcon: appInfo.appIcon.map { .init($0) },
            accentColor: appInfo.accentColor.map { .init($0) },
            supportedDeviceFamilies: appInfo.supportedDeviceFamilies.map { .init($0) },
            supportedInterfaceOrientations: appInfo.supportedInterfaceOrientations.map { .init($0) },
            capabilities: appInfo.capabilities.map { .init($0) },
            appCategory: appInfo.appCategory.map { .init($0) },
            additionalInfoPlistContentFilePath: appInfo.additionalInfoPlistContentFilePath
        )
    }
}

extension ProductSetting.IOSAppInfo.DeviceFamily {
    init(_ deviceFamily: Serialization.ProductSetting.IOSAppInfo.DeviceFamily) {
        switch deviceFamily {
        case .phone: self = .phone
        case .pad: self = .pad
        case .mac: self = .mac
        }
    }
}

extension ProductSetting.IOSAppInfo.DeviceFamilyCondition {
    init(_ condition: Serialization.ProductSetting.IOSAppInfo.DeviceFamilyCondition) {
        self.init(deviceFamilies: condition.deviceFamilies.map { .init($0) })
    }
}

extension ProductSetting.IOSAppInfo.InterfaceOrientation {
    init(_ interfaceOrientation: Serialization.ProductSetting.IOSAppInfo.InterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait(let condition):
            self = .portrait(condition: condition.map { .init($0) })
        case .portraitUpsideDown(let condition):
            self = .portraitUpsideDown(condition: condition.map { .init($0) })
        case .landscapeRight(let condition):
            self = .landscapeRight(condition: condition.map { .init($0) })
        case .landscapeLeft(let condition):
            self = .landscapeLeft(condition: condition.map { .init($0) })
        }
    }
}

extension ProductSetting.IOSAppInfo.AppIcon {
    init(_ icon: Serialization.ProductSetting.IOSAppInfo.AppIcon) {
        switch icon {
        case .placeholder(icon: let icon):
            self = .placeholder(icon: .init(icon))
        case .asset(let name):
            self = .asset(name: name)
        }
    }
}

extension ProductSetting.IOSAppInfo.AppIcon.PlaceholderIcon {
    init(_ icon: Serialization.ProductSetting.IOSAppInfo.AppIcon.PlaceholderIcon) {
        self.init(rawValue: icon.rawValue)
    }
}

extension ProductSetting.IOSAppInfo.AccentColor {
    init(_ color: Serialization.ProductSetting.IOSAppInfo.AccentColor) {
        switch color {
        case .presetColor(let color):
            self = .presetColor(presetColor: .init(color))
        case .asset(let name):
            self = .asset(name: name)
        }
    }
}

extension ProductSetting.IOSAppInfo.AccentColor.PresetColor {
    init(_ color: Serialization.ProductSetting.IOSAppInfo.AccentColor.PresetColor) {
        self.init(rawValue: color.rawValue)
    }
}

extension ProductSetting.IOSAppInfo.Capability {
    init(_ capability: Serialization.ProductSetting.IOSAppInfo.Capability) {
        switch capability {
        case .appTransportSecurity(configuration: let configuration, let condition):
            self.init(purpose: "appTransportSecurity", appTransportSecurityConfiguration: .init(configuration), condition: condition.map { .init($0) })
        case .bluetoothAlways(purposeString: let purposeString, let condition):
            self.init(purpose: "bluetoothAlways", purposeString: purposeString, condition: condition.map { .init($0) })
        case .calendars(purposeString: let purposeString, let condition):
            self.init(purpose: "calendars", purposeString: purposeString, condition: condition.map { .init($0) })
        case .camera(purposeString: let purposeString, let condition):
            self.init(purpose: "camera", purposeString: purposeString, condition: condition.map { .init($0) })
        case .contacts(purposeString: let purposeString, let condition):
            self.init(purpose: "contacts", purposeString: purposeString, condition: condition.map { .init($0) })
        case .faceID(purposeString: let purposeString, let condition):
            self.init(purpose: "faceID", purposeString: purposeString, condition: condition.map { .init($0) })
        case .fileAccess(let location, mode: let mode, let condition):
            self.init(purpose: "fileAccess", fileAccessLocation: location.rawValue, fileAccessMode: mode.rawValue, condition: condition.map { .init($0) })
        case .incomingNetworkConnections(let condition):
            self.init(purpose: "incomingNetworkConnections", condition: condition.map { .init($0) })
        case .localNetwork(purposeString: let purposeString, bonjourServiceTypes: let bonjourServiceTypes, let condition):
            self.init(purpose: "localNetwork", purposeString: purposeString, bonjourServiceTypes: bonjourServiceTypes, condition: condition.map { .init($0) })
        case .locationAlwaysAndWhenInUse(purposeString: let purposeString, let condition):
            self.init(purpose: "locationAlwaysAndWhenInUse", purposeString: purposeString, condition: condition.map { .init($0) })
        case .locationWhenInUse(purposeString: let purposeString, let condition):
            self.init(purpose: "locationWhenInUse", purposeString: purposeString, condition: condition.map { .init($0) })
        case .mediaLibrary(purposeString: let purposeString, let condition):
            self.init(purpose: "mediaLibrary", purposeString: purposeString, condition: condition.map { .init($0) })
        case .microphone(purposeString: let purposeString, let condition):
            self.init(purpose: "microphone", purposeString: purposeString, condition: condition.map { .init($0) })
        case .motion(purposeString: let purposeString, let condition):
            self.init(purpose: "motion", purposeString: purposeString, condition: condition.map { .init($0) })
        case .nearbyInteractionAllowOnce(purposeString: let purposeString, let condition):
            self.init(purpose: "nearbyInteractionAllowOnce", purposeString: purposeString, condition: condition.map { .init($0) })
        case .outgoingNetworkConnections(let condition):
            self.init(purpose: "outgoingNetworkConnections", condition: condition.map { .init($0) })
        case .photoLibrary(purposeString: let purposeString, let condition):
            self.init(purpose: "photoLibrary", purposeString: purposeString, condition: condition.map { .init($0) })
        case .photoLibraryAdd(purposeString: let purposeString, let condition):
            self.init(purpose: "photoLibraryAdd", purposeString: purposeString, condition: condition.map { .init($0) })
        case .reminders(purposeString: let purposeString, let condition):
            self.init(purpose: "reminders", purposeString: purposeString, condition: condition.map { .init($0) })
        case .speechRecognition(purposeString: let purposeString, let condition):
            self.init(purpose: "speechRecognition", purposeString: purposeString, condition: condition.map { .init($0) })
        case .userTracking(purposeString: let purposeString, let condition):
            self.init(purpose: "userTracking", purposeString: purposeString, condition: condition.map { .init($0) })
        }
    }
}

extension ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration {
    init(_ configuration: Serialization.ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration) {
        self.init(
            allowsArbitraryLoadsInWebContent: configuration.allowsArbitraryLoadsInWebContent,
            allowsArbitraryLoadsForMedia: configuration.allowsArbitraryLoadsForMedia,
            allowsLocalNetworking: configuration.allowsLocalNetworking,
            exceptionDomains: configuration.exceptionDomains?.map { .init($0) },
            pinnedDomains: configuration.pinnedDomains?.map { .init($0) }
        )
    }
}

extension ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration.ExceptionDomain {
    init(_ exceptionDomain: Serialization.ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration.ExceptionDomain) {
        self.init(
            domainName: exceptionDomain.domainName,
            includesSubdomains: exceptionDomain.includesSubdomains,
            exceptionAllowsInsecureHTTPLoads: exceptionDomain.exceptionAllowsInsecureHTTPLoads,
            exceptionMinimumTLSVersion: exceptionDomain.exceptionMinimumTLSVersion,
            exceptionRequiresForwardSecrecy: exceptionDomain.exceptionRequiresForwardSecrecy,
            requiresCertificateTransparency: exceptionDomain.requiresCertificateTransparency
        )
    }
}

extension ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration.PinnedDomain {
    init(_ pinnedDomain: Serialization.ProductSetting.IOSAppInfo.AppTransportSecurityConfiguration.PinnedDomain) {
        self.init(
            domainName: pinnedDomain.domainName,
            includesSubdomains: pinnedDomain.includesSubdomains,
            pinnedCAIdentities: pinnedDomain.pinnedCAIdentities,
            pinnedLeafIdentities: pinnedDomain.pinnedLeafIdentities
        )
    }
}

extension ProductSetting.IOSAppInfo.AppCategory {
    init(_ category: Serialization.ProductSetting.IOSAppInfo.AppCategory) {
        self.init(rawValue: category.rawValue)
    }
}
#endif

extension ProductDescription {
    init(_ product: Serialization.Product) throws {
        let productType: ProductType
        switch product.productType {
        case .executable:
            productType = .executable
        case .plugin:
            productType = .plugin
        case .library(let type):
            productType = .library(.init(type))
        }
        #if ENABLE_APPLE_PRODUCT_TYPES
        try self.init(name: product.name, type: productType, targets: product.targets, settings: product.settings.map { .init($0) })
        #else
        try self.init(name: product.name, type: productType, targets: product.targets)
        #endif
    }
}

extension ProductType.LibraryType {
    init(_ libraryType: Serialization.Product.ProductType.LibraryType) {
        switch libraryType {
        case .dynamic:
            self = .dynamic
        case .static:
            self = .static
        case .automatic:
            self = .automatic
        }
    }
}

extension TargetDescription.Dependency {
    init(_ dependency: Serialization.TargetDependency, identityResolver: IdentityResolver) throws {
        switch dependency {
        case .target(let name, let condition):
            self = .target(name: name, condition: condition.map { .init($0) })
        case .product(let name, let package, let moduleAliases, let condition):
            var package: String? = package
            if let packageName = package {
                package = try identityResolver.mappedIdentity(for: .plain(packageName)).description
            }
            self = .product(name: name, package: package, moduleAliases: moduleAliases, condition: condition.map { .init($0) })
        case .byName(let name, let condition):
            self = .byName(name: name, condition: condition.map { .init($0) })
        }
    }
}

extension PackageConditionDescription {
    init(_ condition: Serialization.TargetDependency.Condition) {
        self.init(
            platformNames: condition.platforms?.map { $0.name } ?? [],
            traits: condition.traits
        )
    }
}

extension TargetDescription.TargetKind {
    init(_ type: Serialization.TargetType) {
        switch type {
        case .regular:
            self = .regular
        case .executable:
            self = .executable
        case .test:
            self = .test
        case .system:
            self = .system
        case .binary:
            self = .binary
        case .plugin:
            self = .plugin
        case .macro:
            self = .macro
        }
    }
}

extension TargetDescription.PluginCapability {
    init(_ capability: Serialization.PluginCapability) {
        switch capability {
        case .buildTool:
            self = .buildTool
        case .command(let intent, let permissions):
            self = .command(intent: .init(intent), permissions: permissions.map { .init($0) })
        }
    }
}

extension TargetDescription.PluginCommandIntent {
    init(_ intent: Serialization.PluginCommandIntent) {
        switch intent {
        case .documentationGeneration:
            self = .documentationGeneration
        case .sourceCodeFormatting:
            self = .sourceCodeFormatting
        case .custom(let verb, let description):
            self = .custom(verb: verb, description: description)
        }
    }
}

extension TargetDescription.PluginPermission {
    init(_ permission: Serialization.PluginPermission) {
        switch permission {
        case .allowNetworkConnections(let scope, let reason):
            self = .allowNetworkConnections(scope: .init(scope), reason: reason)
        case .writeToPackageDirectory(let reason):
            self = .writeToPackageDirectory(reason: reason)
        }
    }
}

extension TargetDescription.PluginNetworkPermissionScope {
    init(_ scope: Serialization.PluginNetworkPermissionScope) {
        switch scope {
        case .none:
            self = .none
        case .local(let ports):
            self = .local(ports: ports)
        case .all(ports: let ports):
            self = .all(ports: ports)
        case .docker:
            self = .docker
        case .unixDomainSocket:
            self = .unixDomainSocket
        }
    }
}

extension TargetDescription.PluginUsage {
    init(_ usage: Serialization.PluginUsage) {
        switch usage {
        case .plugin(let name, let package):
            self = .plugin(name: name, package: package)
        }
    }
}

extension TSCUtility.Version {
    init(_ version: Serialization.Version) {
        self.init(
            version.major,
            version.minor,
            version.patch,
            prereleaseIdentifiers: version.prereleaseIdentifiers,
            buildMetadataIdentifiers: version.buildMetadataIdentifiers
        )
    }
}

extension PlatformDescription {
    init(_ platform: Serialization.SupportedPlatform) {
        let platformName = platform.platform.name
        let versionString = platform.version ?? ""

        let versionComponents = versionString.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        var version: [String.SubSequence] = []
        var options: [String.SubSequence] = []

        for (idx, component) in versionComponents.enumerated() {
            if idx < 2 {
                version.append(component)
                continue
            }

            if idx == 2, UInt(component) != nil {
                version.append(component)
                continue
            }

            options.append(component)
        }

        self.init(
            name: platformName,
            version: version.joined(separator: "."),
            options: options.map{ String($0) }
        )
    }
}

extension TargetBuildSettingDescription.Kind {
    static func from(_ name: String, values: [String]) throws -> Self {
        // Diagnose invalid values.
        for item in values {
            let groups = ManifestJSONParser.invalidValueRegex.matchGroups(in: item).flatMap{ $0 }
            if !groups.isEmpty {
                let error = "the build setting '\(name)' contains invalid component(s): \(groups.joined(separator: " "))"
                throw ManifestParseError.runtimeManifestErrors([error])
            }
        }

        switch name {
        case "headerSearchPath":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .headerSearchPath(value)
        case "define":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .define(value)
        case "linkedLibrary":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .linkedLibrary(value)
        case "linkedFramework":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .linkedFramework(value)
        case "interoperabilityMode":
            guard let rawLang = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            guard let lang = TargetBuildSettingDescription.InteroperabilityMode(rawValue: rawLang) else {
                throw InternalError("unknown interoperability mode: \(rawLang)")
            }
            if values.count > 1 {
                throw InternalError("invalid build settings value")
            }
            return .interoperabilityMode(lang)
        case "enableUpcomingFeature":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .enableUpcomingFeature(value)
        case "enableExperimentalFeature":
            guard let value = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            return .enableExperimentalFeature(value)
        case "strictMemorySafety":
            return .strictMemorySafety
        case "unsafeFlags":
            return .unsafeFlags(values)

        case "swiftLanguageVersion", "swiftLanguageMode":
            guard let rawVersion = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }

            if values.count > 1 {
                throw InternalError("invalid build settings value")
            }

            guard let version = SwiftLanguageVersion(string: rawVersion) else {
                throw InternalError("unknown swift language version: \(rawVersion)")
            }

            return .swiftLanguageMode(version)
        case "treatAllWarnings":
            guard values.count == 1 else {
                throw InternalError("invalid build settings value")
            }

            let rawLevel = values[0]

            guard let level = TargetBuildSettingDescription.WarningLevel(rawValue: rawLevel) else {
                throw InternalError("unknown warning treat level: \(rawLevel)")
            }

            return .treatAllWarnings(level)

        case "treatWarning":
            guard values.count == 2 else {
                throw InternalError("invalid build settings value")
            }

            let name = values[0]
            let rawValue = values[1]

            guard let level = TargetBuildSettingDescription.WarningLevel(rawValue: rawValue) else {
                throw InternalError("unknown warning treat level: \(rawValue)")
            }

            return .treatWarning(name, level)

        case "enableWarning":
            guard values.count == 1 else {
                throw InternalError("invalid build settings value")
            }
            return .enableWarning(values[0])

        case "disableWarning":
            guard values.count == 1 else {
                throw InternalError("invalid build settings value")
            }
            return .disableWarning(values[0])

        case "defaultIsolation":
            guard let rawValue = values.first else {
                throw InternalError("invalid (empty) build settings value")
            }
            guard let isolation = TargetBuildSettingDescription.DefaultIsolation(rawValue: rawValue) else {
                throw InternalError("unknown default isolation: \(rawValue)")
            }

            return .defaultIsolation(isolation)
        default:
            throw InternalError("invalid build setting \(name)")
        }
    }
}

extension PackageConditionDescription {
    init(_ condition: Serialization.BuildSettingCondition) {
        self.init(platformNames: condition.platforms?.map { $0.name } ?? [], config: condition.config?.config, traits: condition.traits)
    }
}

extension TargetBuildSettingDescription.Setting {
    init(_ setting: Serialization.CSetting) throws {
        self.init(
            tool: .c,
            kind: try .from(setting.data.name, values: setting.data.value),
            condition: setting.data.condition.map { .init($0) }
        )
    }

    init(_ setting: Serialization.CXXSetting) throws {
        self.init(
            tool: .cxx,
            kind: try .from(setting.data.name, values: setting.data.value),
            condition: setting.data.condition.map { .init($0) }
        )
    }

    init(_ setting: Serialization.LinkerSetting) throws {
        self.init(
            tool: .linker,
            kind: try .from(setting.data.name, values: setting.data.value),
            condition: setting.data.condition.map { .init($0) }
        )
    }

    init(_ setting: Serialization.SwiftSetting) throws {
        self.init(
            tool: .swift,
            kind: try .from(setting.data.name, values: setting.data.value),
            condition: setting.data.condition.map { .init($0) }
        )
    }
}

extension TraitDescription {
    init(_ trait: Serialization.Trait) {
        self.init(
            name: trait.name,
            description: trait.description,
            enabledTraits: trait.enabledTraits
        )
    }
}

extension PackageDependency.Trait {
    init(_ trait: Serialization.PackageDependency.Trait) {
        self.init(
            name: trait.name,
            condition: trait.condition.flatMap { .init($0) }
        )
    }
}


extension PackageDependency.Trait.Condition {
    init(_ condition: Serialization.PackageDependency.Trait.Condition) {
        self.init(traits: condition.traits)
    }
}

extension MappablePackageDependency {
    fileprivate init(_ seed: Serialization.PackageDependency, parentPackagePath: AbsolutePath) {
        switch seed.kind {
        case .fileSystem(let name, let path):
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .fileSystem(
                    name: name,
                    path: path
                ),
                productFilter: .everything,
                traits: seed.traits.flatMap { Set($0.map { PackageDependency.Trait.init($0) } ) }
            )
        case .sourceControl(let name, let location, let requirement):
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .sourceControl(
                    name: name,
                    location: location,
                    requirement: .init(requirement)
                ),
                productFilter: .everything,
                traits: seed.traits.flatMap { Set($0.map { PackageDependency.Trait.init($0) } ) }
            )
        case .registry(let id, let requirement):
            self.init(
                parentPackagePath: parentPackagePath,
                kind: .registry(
                    id: id,
                    requirement: .init(requirement)
                ),
                productFilter: .everything,
                traits: seed.traits.flatMap { Set($0.map { PackageDependency.Trait.init($0) } ) }
            )
        }
    }
}
