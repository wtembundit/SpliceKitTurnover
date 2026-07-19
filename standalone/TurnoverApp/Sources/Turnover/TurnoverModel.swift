import AppKit
import AVFoundation
import CoreText
import CoreImage
import Foundation
import Metal
import QuartzCore
import UniformTypeIdentifiers

@MainActor
final class TurnoverModel: ObservableObject {
    nonisolated static let burnInTextInsetX: CGFloat = 10
    nonisolated static let burnInTextInsetY: CGFloat = 6
    nonisolated static let burnInTextCornerRadius: CGFloat = 5

    enum Tool: String, CaseIterable, Identifiable {
        case exportMarkers = "Marker"
        case conformPrep = "Conform Prep"
        case vfxNaming = "VFX Naming"
        case autoMarker = "Auto Marker"
        case vfxPullEDL = "VFX Pull EDL"
        case vfxShotList = "VFX Shot List"
        case vfxTimeline = "VFX Timeline"
        case dataBurnIn = "Data Burn-In"

        var id: String { rawValue }

        var selectorName: String {
            switch self {
            case .vfxNaming: "Naming"
            case .vfxPullEDL: "Pull EDL"
            case .vfxShotList: "Shot List"
            case .vfxTimeline: "Timeline"
            case .exportMarkers: "Marker"
            default: rawValue
            }
        }
    }

    enum BurnInAnchor: String, CaseIterable, Identifiable, Codable, Sendable {
        case topLeft = "Top Left"
        case topCenter = "Top Center"
        case topRight = "Top Right"
        case middleLeft = "Middle Left"
        case middleCenter = "Middle Center"
        case middleRight = "Middle Right"
        case bottomLeft = "Bottom Left"
        case bottomCenter = "Bottom Center"
        case bottomRight = "Bottom Right"

        var id: String { rawValue }
    }

    enum BurnInAnalysisDetail: String, CaseIterable, Identifiable, Codable, Sendable {
        case transform = "Transform"
        case position = "Position"
        case scale = "Scale"
        case rotation = "Rotation"
        case crop = "Crop"
        case distort = "Distort"
        case spatialConform = "Spatial Conform"
        case retime = "Retime"
        case stabilize = "Stabilize"
        case opticalFlow = "Optical Flow"

        var id: String { rawValue }
    }

    enum BurnInSourceLayerDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case compact = "Compact"
        case detailed = "Detailed"

        var id: String { rawValue }
    }

    enum BurnInSourceLayerDetailLayout: String, CaseIterable, Identifiable, Codable, Sendable {
        case oneLine = "One Line"
        case twoLines = "Two Lines"

        var id: String { rawValue }
    }

    enum BurnInSourceLayerDetail: String, CaseIterable, Identifiable, Codable, Sendable {
        case sourceFilename = "Source Filename"
        case sourceTC = "Source TC"
        case sourceFrame = "Source Frame"
        case sourceFPS = "Source FPS"
        case clipName = "Clip Name"
        case sourceName = "Source Name"
        case reel = "Reel"
        case scene = "Scene"
        case take = "Take"
        case cameraName = "Camera Name"
        case angle = "Angle"
        case customMetadata = "Custom Metadata"
        case retime = "Retime"

        var id: String { rawValue }
    }

    enum BurnInTextColor: String, CaseIterable, Identifiable, Codable, Sendable {
        case white = "White"
        case yellow = "Yellow"
        case cyan = "Cyan"
        case red = "Red"
        case black = "Black"

        var id: String { rawValue }
    }

    struct BurnInRGBAColor: Codable, Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static func preset(_ color: BurnInTextColor) -> BurnInRGBAColor {
            switch color {
            case .white: BurnInRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
            case .yellow: BurnInRGBAColor(red: 1, green: 0.84, blue: 0, alpha: 1)
            case .cyan: BurnInRGBAColor(red: 0, green: 0.76, blue: 1, alpha: 1)
            case .red: BurnInRGBAColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .black: BurnInRGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
            }
        }
    }

    enum BurnInExportMode: String, CaseIterable, Identifiable, Codable, Sendable {
        case transparentOverlay = "Transparent Overlay"
        case burnedInReference = "Burned-In Reference"

        var id: String { rawValue }
    }

    enum BurnInExportCodec: String, CaseIterable, Identifiable, Codable, Sendable {
        case proRes422Proxy = "ProRes 422 Proxy"
        case proRes422LT = "ProRes 422 LT"
        case proRes422 = "ProRes 422"
        case proRes4444 = "ProRes 4444"
        case proRes422HQ = "ProRes 422 HQ"
        case h264 = "H.264"
        case hevc = "HEVC"

        var id: String { rawValue }

        var usesBitrate: Bool {
            self == .h264 || self == .hevc
        }

        static var burnedInReleaseCodecs: [BurnInExportCodec] {
            [.h264, .hevc]
        }

        var fileExtension: String {
            switch self {
            case .h264, .hevc: "mp4"
            default: "mov"
            }
        }

        var outputFileType: AVFileType {
            switch self {
            case .h264, .hevc: .mp4
            default: .mov
            }
        }

        var exportPresetName: String {
            switch self {
            case .proRes4444: "com.apple.quicktime-movie.apple-prores-4444"
            case .proRes422HQ: "com.apple.quicktime-movie.apple-prores-422-hq"
            case .proRes422, .proRes422LT, .proRes422Proxy: "com.apple.quicktime-movie.apple-prores-422"
            case .hevc: AVAssetExportPresetHEVCHighestQuality
            case .h264: AVAssetExportPresetHighestQuality
            }
        }
    }

    enum BurnInExportContainer: String, CaseIterable, Identifiable, Codable, Sendable {
        case mp4 = "MP4"
        case mov = "MOV"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .mov: "mov"
            }
        }

        var outputFileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            }
        }
    }

    struct BurnInStyle: Codable, Equatable, Sendable {
        var fontSize: Double
        var horizontalPadding: Double
        var verticalPadding: Double
        var textColor: BurnInTextColor
        var textColorValue: BurnInRGBAColor?
        var textOpacity: Double
        var backgroundOpacity: Double

        enum CodingKeys: String, CodingKey {
            case fontSize
            case horizontalPadding
            case verticalPadding
            case textColor
            case textColorValue
            case textOpacity
            case backgroundOpacity
        }

        init(
            fontSize: Double,
            horizontalPadding: Double,
            verticalPadding: Double,
            textColor: BurnInTextColor,
            textColorValue: BurnInRGBAColor? = nil,
            textOpacity: Double,
            backgroundOpacity: Double
        ) {
            self.fontSize = fontSize
            self.horizontalPadding = horizontalPadding
            self.verticalPadding = verticalPadding
            self.textColor = textColor
            self.textColorValue = textColorValue
            self.textOpacity = textOpacity
            self.backgroundOpacity = backgroundOpacity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
            horizontalPadding = try container.decodeIfPresent(Double.self, forKey: .horizontalPadding) ?? 48
            verticalPadding = try container.decodeIfPresent(Double.self, forKey: .verticalPadding) ?? 36
            textColor = try container.decodeIfPresent(BurnInTextColor.self, forKey: .textColor) ?? .white
            textColorValue = try container.decodeIfPresent(BurnInRGBAColor.self, forKey: .textColorValue)
            textOpacity = try container.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1
            backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.35
        }
    }

    struct BurnInField: Identifiable, Codable, Equatable, Sendable {
        var anchor: BurnInAnchor
        var enabled: Bool
        var template: String
        var usesGlobalStyle: Bool
        var fontSize: Double
        var horizontalPadding: Double
        var verticalPadding: Double
        var textColor: BurnInTextColor
        var textColorValue: BurnInRGBAColor?
        var textOpacity: Double
        var backgroundOpacity: Double

        var id: BurnInAnchor { anchor }

        enum CodingKeys: String, CodingKey {
            case anchor
            case enabled
            case template
            case usesGlobalStyle
            case fontSize
            case horizontalPadding
            case verticalPadding
            case textColor
            case textColorValue
            case textOpacity
            case backgroundOpacity
        }

        init(
            anchor: BurnInAnchor,
            enabled: Bool,
            template: String,
            usesGlobalStyle: Bool,
            fontSize: Double,
            horizontalPadding: Double,
            verticalPadding: Double,
            textColor: BurnInTextColor,
            textColorValue: BurnInRGBAColor? = nil,
            textOpacity: Double,
            backgroundOpacity: Double
        ) {
            self.anchor = anchor
            self.enabled = enabled
            self.template = template
            self.usesGlobalStyle = usesGlobalStyle
            self.fontSize = fontSize
            self.horizontalPadding = horizontalPadding
            self.verticalPadding = verticalPadding
            self.textColor = textColor
            self.textColorValue = textColorValue
            self.textOpacity = textOpacity
            self.backgroundOpacity = backgroundOpacity
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try container.decode(BurnInAnchor.self, forKey: .anchor)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            template = try container.decode(String.self, forKey: .template)
            usesGlobalStyle = try container.decodeIfPresent(Bool.self, forKey: .usesGlobalStyle) ?? true
            fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 20
            horizontalPadding = try container.decodeIfPresent(Double.self, forKey: .horizontalPadding) ?? 48
            verticalPadding = try container.decodeIfPresent(Double.self, forKey: .verticalPadding) ?? 36
            textColor = try container.decodeIfPresent(BurnInTextColor.self, forKey: .textColor) ?? .white
            textColorValue = try container.decodeIfPresent(BurnInRGBAColor.self, forKey: .textColorValue)
            textOpacity = try container.decodeIfPresent(Double.self, forKey: .textOpacity) ?? 1
            backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.35
        }
    }

    enum MarkerKind: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case todo = "To Do"
        case chapter = "Chapter"

        var id: String { rawValue }
        var argument: String { self == .todo ? "todo" : rawValue.lowercased() }
    }

    enum MarkerExportKind: String, CaseIterable, Identifiable {
        case all = "All Markers"
        case standard = "Standard"
        case todo = "To Do"
        case chapter = "Chapter"
        case recheck = "Turnover Recheck"

        var id: String { rawValue }

        var argument: String {
            switch self {
            case .all: "all"
            case .todo: "todo"
            case .recheck: "recheck"
            default: rawValue.lowercased()
            }
        }
    }

    enum MarkerExportFormat: String, CaseIterable, Identifiable {
        case edl = "EDL"
        case csv = "CSV"
        case txt = "TXT"

        var id: String { rawValue }
        var argument: String {
            switch self {
            case .edl: "edl"
            case .csv: "csv"
            case .txt: "txt"
            }
        }
    }

    enum NamingMode: String, CaseIterable, Identifiable {
        case auto = "Auto Number"
        case reset = "Reset to XXXX"

        var id: String { rawValue }
        var argument: String { self == .auto ? "auto" : "reset" }
    }

    enum TimelinePlacement: String, CaseIterable, Identifiable {
        case connected = "Connected"
        case replace = "Replace"
        case audition = "Audition"

        var id: String { rawValue }
        var argument: String { rawValue.lowercased() }
    }

    enum JobState: Equatable {
        case idle
        case ready
        case running
        case succeeded
        case failed(String)
    }

    struct BurnInCondition: Identifiable, Codable, Equatable, Sendable {
        enum Subject: String, CaseIterable, Identifiable, Codable, Sendable {
            case audioRole = "Audio Role"
            case sourceFile = "Source File"
            case vfxNumber = "VFX Number"
            case vfxNote = "VFX Note"
            case analysis = "Analysis"

            var id: String { rawValue }
        }

        var id: UUID
        var subject: Subject
        var contains: String
        var message: String

        init(
            id: UUID = UUID(),
            subject: Subject = .audioRole,
            contains: String = "",
            message: String = ""
        ) {
            self.id = id
            self.subject = subject
            self.contains = contains
            self.message = message
        }
    }

    private struct VisibleFrameIndex: Decodable, Sendable {
        struct Timeline: Decodable, Sendable {
            let startSeconds: Double
            let durationSeconds: Double
            let frameDurationSeconds: Double
            let frameRate: String?
            let tcFormat: String
            let width: Int?
            let height: Int?
            let colorSpace: String?
            let formatName: String?
        }

        struct BurnInMetadata: Decodable, Sendable {
            struct Entry: Decodable, Hashable, Sendable {
                let key: String?
                let label: String
                let value: String
                let source: String?
            }

            let sourceName: String?
            let reel: String?
            let scene: String?
            let take: String?
            let camera: String?
            let angle: String?
            let custom: String?
            let all: String?
            let entries: [Entry]?
        }

        struct VideoSegment: Decodable, Sendable {
            let index: Int?
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let clipName: String?
            let sourceFilename: String
            let sourceName: String?
            let sourceInSeconds: Double
            let sourceOutSeconds: Double
            let sourceFrameDuration: Double
            let sourceFrameRate: String?
            let sourceTcFormat: String
            let layerRole: String?
            let timelineLane: String?
            let nestingDepth: Int?
            let metadata: BurnInMetadata?
        }

        struct FrameSample: Decodable, Sendable {
            struct VisibleLayer: Decodable, Sendable {
                let layerIndex: Int
                let segmentIndex: Int?
                let clipName: String?
                let sourceFilename: String?
                let sourceName: String?
                let sourceSeconds: Double
                let sourceFrameDuration: Double?
                let sourceFrameRate: String?
                let sourceTcFormat: String?
                let layerRole: String?
                let timelineLane: String?
                let nestingDepth: Int?
                let metadata: BurnInMetadata?
            }

            let frame: Int
            let timelineSeconds: Double
            let segmentIndex: Int?
            let clipName: String?
            let sourceFilename: String?
            let sourceName: String?
            let sourceSeconds: Double
            let sourceFrameDuration: Double?
            let sourceFrameRate: String?
            let sourceTcFormat: String?
            let metadata: BurnInMetadata?
            let visibleLayers: [VisibleLayer]?
        }

        struct VFXTitle: Decodable, Sendable {
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let vfxNumber: String
            let note: String
        }

        struct AudioRole: Decodable, Sendable {
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
            let role: String
        }

        struct AnalysisItem: Decodable, Sendable {
            let label: String
            let key: String?
            let value: String?
            let owner: String
            let ownerName: String?
            let detail: String
            let timelineStartSeconds: Double
            let timelineEndSeconds: Double
        }

        let project: String
        let event: String
        let timeline: Timeline
        let videoSegments: [VideoSegment]
        let frameSamples: [FrameSample]?
        let vfxTitles: [VFXTitle]
        let audioRoles: [AudioRole]
        let analysisItems: [AnalysisItem]?
    }

    private struct BurnInLayerSnapshot: Sendable {
        let layerIndex: Int
        let clipName: String?
        let sourceFilename: String
        let sourceName: String?
        let sourceSeconds: Double
        let sourceFrameDuration: Double
        let sourceFrameRate: String?
        let sourceTcFormat: String
        let layerRole: String
        let timelineLane: String?
        let nestingDepth: Int
        let metadata: VisibleFrameIndex.BurnInMetadata?
    }

    private struct BurnInTextLayout {
        let attributed: CFAttributedString
        let framesetter: CTFramesetter?
        let line: CTLine?
        let size: CGSize
        let textLength: Int
    }

    private struct BurnInExportStats: Sendable {
        let frameCount: Int
        let timelineDurationSeconds: Double
        let elapsedSeconds: Double
        let outputBytes: Int64

        var renderFPS: Double {
            guard elapsedSeconds > 0 else { return 0 }
            return Double(frameCount) / elapsedSeconds
        }

        var realtimeMultiple: Double {
            guard timelineDurationSeconds > 0, elapsedSeconds > 0 else { return 0 }
            return timelineDurationSeconds / elapsedSeconds
        }
    }

    private struct BurnInRenderSnapshot: Sendable {
        let fields: [BurnInField]
        let globalStyle: BurnInStyle
        let showLabels: Bool
        let showFileExtensions: Bool
        let labelOverrides: [String: Bool]
        let analysisDetailOptions: [String: Bool]
        let metadataSelections: [String: Bool]
        let conditions: [BurnInCondition]
        let sourceLayerLimit: Int
        let sourceLayerDisplayMode: BurnInSourceLayerDisplayMode
        let sourceLayerDetailLayout: BurnInSourceLayerDetailLayout
        let sourceLayerDetailOptions: [String: Bool]
        let exportMode: BurnInExportMode
        let exportCodec: BurnInExportCodec
        let exportContainer: BurnInExportContainer
        let exportBitrateMbps: Double
        let customizerVisible: Bool
        let manifest: VisibleFrameIndex
        let samplesByFrame: [Int: VisibleFrameIndex.FrameSample]
        let frameDurationSeconds: Double
        let exportStartSeconds: Double
        let durationSeconds: Double
    }

    private enum BurnInExportJobKind: Sendable {
        case burnedInVideo(source: URL)
        case transparentOverlay
    }

    private struct BurnInExportJob: Sendable {
        let id: UUID
        let kind: BurnInExportJobKind
        let destination: URL
        let snapshot: BurnInRenderSnapshot
    }

    struct BurnInExportQueueItem: Identifiable, Equatable {
        let id: UUID
        let filename: String
        let mode: String
        let codec: String
        let destinationPath: String
    }

    private final class BurnInAudioPipe {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var pendingSample: CMSampleBuffer?
        var finished = false

        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }
    }

    struct SavedBurnInSettings: Codable, Equatable {
        let fields: [BurnInField]
        let globalStyle: BurnInStyle?
        let audioRoleFilter: String
        let conditionalText: String
        let conditions: [BurnInCondition]?
        let showLabels: Bool?
        let showFileExtensions: Bool?
        let labelOverrides: [String: Bool]?
        let analysisDetailOptions: [String: Bool]?
        let exportMode: BurnInExportMode?
        let exportCodec: BurnInExportCodec?
        let exportContainer: BurnInExportContainer?
        let exportBitrateMbps: Double?
        let revealExportWhenDone: Bool?
        let metadataSelections: [String: Bool]?
        let sourceLayerLimit: Int?
        let sourceLayerDisplayMode: BurnInSourceLayerDisplayMode?
        let sourceLayerDetailLayout: BurnInSourceLayerDetailLayout?
        let sourceLayerDetailOptions: [String: Bool]?
    }

    struct BurnInNamedPreset: Identifiable, Codable, Equatable {
        var id: String
        var name: String
        var settings: SavedBurnInSettings
    }

    private struct BurnInPresetLibrary: Codable {
        var selectedID: String?
        var presets: [BurnInNamedPreset]
    }

    @Published var sourceURL: URL?
    @Published var outputURL: URL?
    @Published var reportURL: URL?
    @Published var state: JobState = .idle
    @Published var log = "Drop an FCPXML file to begin."
    @Published var openInFinalCut = false
    @Published var selectedTool: Tool = .conformPrep
    @Published var markerKind: MarkerKind = .standard
    @Published var markerExportKind: MarkerExportKind = .all
    @Published var markerExportFormat: MarkerExportFormat = .edl
    @Published var renameMarkers = false
    @Published var handleFrames = 0
    @Published var namingMode: NamingMode = .auto
    @Published var namingStart = 10
    @Published var namingStep = 10
    @Published var deliveryFolderURL: URL?
    @Published var timelineHandleFrames = 0
    @Published var timelineSlateFrames = 0
    @Published var timelinePlacement: TimelinePlacement = .connected
    @Published var referenceMovieURL: URL?
    @Published var cacheSizeText = "0 KB"
    @Published var updateStatus = "Check for Updates"
    @Published var isVFXNamingTemplateInstalled = false
    @Published var templateInstallStatus = ""
    @Published var burnInFields = TurnoverModel.defaultBurnInFields()
    @Published var burnInGlobalStyle = TurnoverModel.defaultBurnInStyle()
    @Published var selectedBurnInAnchor: BurnInAnchor = .topLeft
    @Published var burnInAudioRoleFilter = ""
    @Published var burnInConditionalText = "TEMP AUDIO"
    @Published var burnInConditions: [BurnInCondition] = []
    @Published var burnInShowLabels = true
    @Published var burnInShowFileExtensions = true
    @Published var burnInLabelOverrides: [String: Bool] = [:]
    @Published var burnInAnalysisDetailOptions = TurnoverModel.defaultBurnInAnalysisDetailOptions()
    @Published var burnInExportMode: BurnInExportMode = .transparentOverlay
    @Published var burnInExportCodec: BurnInExportCodec = .proRes4444
    @Published var burnInExportContainer: BurnInExportContainer = .mp4
    @Published var burnInExportBitrateMbps = 20.0
    @Published var burnInRevealExportWhenDone = true
    @Published var burnInExportProgress: Double?
    @Published var burnInExportStatus = ""
    @Published var burnInExportFilename = ""
    @Published var burnInExportQueueCount = 0
    @Published var burnInCurrentExport: BurnInExportQueueItem?
    @Published var burnInQueuedExports: [BurnInExportQueueItem] = []
    @Published var burnInLastExportSummary = ""
    @Published var burnInMetadataSelections: [String: Bool] = [:]
    @Published var burnInSourceLayerLimit = 1
    @Published var burnInSourceLayerDisplayMode: BurnInSourceLayerDisplayMode = .compact
    @Published var burnInSourceLayerDetailLayout: BurnInSourceLayerDetailLayout = .oneLine
    @Published var burnInSourceLayerDetailOptions = TurnoverModel.defaultBurnInSourceLayerDetailOptions()
    @Published var burnInPositionSeconds = 0.0
    @Published var burnInDurationSeconds = 0.0
    @Published var burnInExportInSeconds: Double?
    @Published var burnInExportOutSeconds: Double?
    @Published var burnInPresets: [BurnInNamedPreset] = []
    @Published var selectedBurnInPresetID = ""
    @Published var burnInVideoURL: URL?
    @Published var burnInCustomizerVisible = false
    @Published var shouldOpenBurnInCustomizerAfterBuild = false

    private var visibleFrameIndex: VisibleFrameIndex?
    private var visibleFrameSamplesByFrame: [Int: VisibleFrameIndex.FrameSample] = [:]
    private var burnInExportTask: Task<Void, Never>?
    private var burnInExportQueue: [BurnInExportJob] = []
    private let burnInSettingsKey = "Turnover.DataBurnIn.CustomPreset.v2"
    private let burnInPresetLibraryKey = "Turnover.DataBurnIn.PresetLibrary.v3"

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/wtembundit/SpliceKitTurnover/releases/latest")!

    var burnInExportEstimateText: String {
        guard burnInDurationSeconds > 0 else { return "Estimated size will appear after building the Burn-In cache." }
        let width = visibleFrameIndex?.timeline.width ?? 1920
        let height = visibleFrameIndex?.timeline.height ?? 1080
        let frameDuration = max(burnInFrameDurationSeconds, 1.0 / 24.0)
        let codec: BurnInExportCodec = burnInExportMode == .transparentOverlay ? .proRes4444 : burnInExportCodec
        let range = normalizedBurnInExportRange()
        let estimated = Self.estimatedBurnInExportBytes(
            width: max(16, width),
            height: max(16, height),
            frameDuration: frameDuration,
            durationSeconds: range.duration,
            codec: codec,
            bitrateMbps: burnInExportBitrateMbps,
            needsAudioMux: false,
            isTransparentOverlay: burnInExportMode == .transparentOverlay
        )
        return "Estimated output: \(Self.formatBytes(estimated))"
    }

    init() {
        loadBurnInPresetLibrary()
        do {
            try CacheManager.prepareAndClean()
            refreshCacheSize()
            refreshVFXNamingTemplateStatus()
            checkForUpdates(showResult: false)
        } catch {
            log = "Cache cleanup warning: \(error.localizedDescription)"
        }
    }

    func refreshVFXNamingTemplateStatus() {
        isVFXNamingTemplateInstalled = FileManager.default.fileExists(
            atPath: vfxNamingTemplateDestination.appendingPathComponent("VFX NAMING.moti").path
        )
    }

    func installVFXNamingTemplate() {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("Titles.localized", isDirectory: true)
            .appendingPathComponent("VFX", isDirectory: true)
            .appendingPathComponent("VFX Naming", isDirectory: true),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("VFX NAMING.moti").path) else {
            templateInstallStatus = "Bundled template is missing."
            return
        }

        do {
            let destination = vfxNamingTemplateDestination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: vfxNamingTemplateDestination.path) {
                try FileManager.default.removeItem(at: vfxNamingTemplateDestination)
            }
            try FileManager.default.copyItem(at: source, to: vfxNamingTemplateDestination)
            refreshVFXNamingTemplateStatus()
            templateInstallStatus = "Installed. Restart Final Cut Pro to refresh Titles."
        } catch {
            templateInstallStatus = "Install failed: \(error.localizedDescription)"
        }
    }

    private var vfxNamingTemplateDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Motion Templates.localized/Titles.localized/VFX/VFX Naming", isDirectory: true)
    }

    func checkForUpdates(showResult: Bool = true) {
        updateStatus = "Checking..."
        Task {
            do {
                var request = URLRequest(url: latestReleaseAPI)
                request.timeoutInterval = 10
                request.setValue("Turnover-Standalone", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NodeRunner.ProcessFailure(message: "GitHub returned an unexpected response.")
                }
                let release = try JSONDecoder().decode(LatestRelease.self, from: data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                let available = compareVersions(current, release.tagName) == .orderedAscending
                updateStatus = available ? "\(release.tagName) Available" : "Up to Date"
                if available || showResult {
                    showUpdateResult(current: current, release: release, available: available)
                }
            } catch {
                updateStatus = "Check Failed"
                if showResult {
                    let alert = NSAlert()
                    alert.messageText = "Update check failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .compare(rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), options: .numeric)
    }

    private func showUpdateResult(current: String, release: LatestRelease, available: Bool) {
        let alert = NSAlert()
        alert.messageText = available ? "Turnover update available" : "Turnover is up to date"
        alert.informativeText = available
            ? "Turnover \(release.tagName) is available. You are using \(current)."
            : "You are using the latest version (\(current))."
        if available { alert.addButton(withTitle: "Open Download Page") }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           available,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    var nodeStatus: String {
        guard let node = NodeRunner.findNode() else { return "Runtime: missing" }
        let bundledRuntime = Bundle.main.bundleURL.pathComponents.contains("Turnover.app")
            && node.path.hasPrefix(Bundle.main.resourceURL?.path ?? "")
        return bundledRuntime ? "Bundled runtime ready" : "Node.js: \(node.path)"
    }

    var canRun: Bool {
        sourceURL != nil
            && state != .running
            && NodeRunner.findNode() != nil
            && (selectedTool != .vfxShotList || referenceMovieURL != nil)
    }

    var burnInTimelineLabel: String {
        guard let manifest = visibleFrameIndex else { return "Build the preview cache to inspect timeline values." }
        let absolute = manifest.timeline.startSeconds + burnInPositionSeconds
        return "Frame preview: \(Self.formatTimecode(seconds: absolute, frameDuration: manifest.timeline.frameDurationSeconds, tcFormat: manifest.timeline.tcFormat))"
    }

    var burnInFrameDurationSeconds: Double {
        visibleFrameIndex?.timeline.frameDurationSeconds ?? (1.0 / 24.0)
    }

    var burnInExportRangeLabel: String {
        guard burnInDurationSeconds > 0 else { return "Full timeline" }
        let range = normalizedBurnInExportRange()
        guard range.start > 0 || range.duration < burnInDurationSeconds else { return "Full timeline" }
        let frameDuration = burnInFrameDurationSeconds
        let inLabel = Self.formatTimecode(seconds: (visibleFrameIndex?.timeline.startSeconds ?? 0) + range.start, frameDuration: frameDuration, tcFormat: visibleFrameIndex?.timeline.tcFormat ?? "NDF")
        let outLabel = Self.formatTimecode(seconds: (visibleFrameIndex?.timeline.startSeconds ?? 0) + range.start + range.duration, frameDuration: frameDuration, tcFormat: visibleFrameIndex?.timeline.tcFormat ?? "NDF")
        return "Range: \(inLabel) -> \(outLabel)"
    }

    func markBurnInExportIn() {
        let position = min(max(burnInPositionSeconds, 0), burnInDurationSeconds)
        burnInExportInSeconds = position
        if let out = burnInExportOutSeconds, out <= position {
            burnInExportOutSeconds = nil
        }
    }

    func markBurnInExportOut() {
        let position = min(max(burnInPositionSeconds, 0), burnInDurationSeconds)
        burnInExportOutSeconds = position
        if let markIn = burnInExportInSeconds, markIn >= position {
            burnInExportInSeconds = nil
        }
    }

    func clearBurnInExportRange() {
        burnInExportInSeconds = nil
        burnInExportOutSeconds = nil
    }

    private func normalizedBurnInExportRange() -> (start: Double, duration: Double) {
        let frameDuration = max(burnInFrameDurationSeconds, 1.0 / 24.0)
        let fullDuration = max(burnInDurationSeconds, frameDuration)
        let start = min(max(burnInExportInSeconds ?? 0, 0), fullDuration)
        let end = min(max(burnInExportOutSeconds ?? fullDuration, 0), fullDuration)
        guard end - start >= frameDuration else {
            return (0, fullDuration)
        }
        return (start, end - start)
    }

    private func currentBurnInRenderSnapshot() -> BurnInRenderSnapshot? {
        guard let manifest = visibleFrameIndex else { return nil }
        let range = normalizedBurnInExportRange()
        return BurnInRenderSnapshot(
            fields: burnInFields,
            globalStyle: burnInGlobalStyle,
            showLabels: burnInShowLabels,
            showFileExtensions: burnInShowFileExtensions,
            labelOverrides: burnInLabelOverrides,
            analysisDetailOptions: burnInAnalysisDetailOptions,
            metadataSelections: burnInMetadataSelections,
            conditions: burnInConditions,
            sourceLayerLimit: burnInSourceLayerLimit,
            sourceLayerDisplayMode: burnInSourceLayerDisplayMode,
            sourceLayerDetailLayout: burnInSourceLayerDetailLayout,
            sourceLayerDetailOptions: burnInSourceLayerDetailOptions,
            exportMode: burnInExportMode,
            exportCodec: burnInExportCodec,
            exportContainer: Self.effectiveBurnInExportContainer(codec: burnInExportCodec, requested: burnInExportContainer),
            exportBitrateMbps: burnInExportBitrateMbps,
            customizerVisible: burnInCustomizerVisible,
            manifest: manifest,
            samplesByFrame: visibleFrameSamplesByFrame,
            frameDurationSeconds: max(manifest.timeline.frameDurationSeconds, 1.0 / 24.0),
            exportStartSeconds: range.start,
            durationSeconds: max(range.duration, 0)
        )
    }

    func burnInPreviewText(for field: BurnInField, at positionSeconds: Double? = nil) -> String {
        guard let snapshot = currentBurnInRenderSnapshot() else { return field.template }
        return Self.burnInPreviewText(for: field, at: positionSeconds ?? burnInPositionSeconds, snapshot: snapshot)
    }

    func burnInTimelineRenderSize() -> CGSize {
        guard let manifest = visibleFrameIndex else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(
            width: max(16, manifest.timeline.width ?? 1920),
            height: max(16, manifest.timeline.height ?? 1080)
        )
    }

    nonisolated private static func burnInPreviewText(for field: BurnInField, at previewPositionSeconds: Double, snapshot: BurnInRenderSnapshot) -> String {
        let manifest = snapshot.manifest
        func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        func ownerAlias(_ value: String?) -> String? {
            guard let trimmed = nonEmpty(value) else { return nil }
            let filename = (trimmed as NSString).lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            let alias = (stem.isEmpty ? filename : stem)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return alias.isEmpty ? nil : alias
        }
        func sampleHasSource(_ sample: VisibleFrameIndex.FrameSample?) -> Bool {
            guard let sample else { return false }
            if sample.segmentIndex != nil { return true }
            if nonEmpty(sample.sourceFilename) != nil { return true }
            return (sample.visibleLayers ?? []).contains {
                $0.segmentIndex != nil || nonEmpty($0.sourceFilename) != nil
            }
        }
        func exactSample(frame: Int) -> VisibleFrameIndex.FrameSample? {
            guard frame >= 0 else { return nil }
            return snapshot.samplesByFrame[frame]
        }
        func bestSample(preferred: Int, fallback: Int?) -> VisibleFrameIndex.FrameSample? {
            var candidates = [preferred]
            if let fallback { candidates.append(fallback) }
            candidates += [preferred - 1, preferred + 1, preferred - 2, preferred + 2]
            if let fallback { candidates += [fallback - 1, fallback + 1] }
            var seen = Set<Int>()
            let uniqueCandidates = candidates.filter { frame in
                frame >= 0 && seen.insert(frame).inserted
            }
            for frame in uniqueCandidates {
                let sample = exactSample(frame: frame)
                if sampleHasSource(sample) { return sample }
            }
            return exactSample(frame: preferred) ?? fallback.flatMap { exactSample(frame: $0) }
        }
        func videoSegment(at absoluteSeconds: Double) -> VisibleFrameIndex.VideoSegment? {
            manifest.videoSegments
                .filter { absoluteSeconds >= $0.timelineStartSeconds && absoluteSeconds < $0.timelineEndSeconds }
                .last
        }
        func videoSegment(index: Int?) -> VisibleFrameIndex.VideoSegment? {
            guard let index else { return nil }
            return manifest.videoSegments.first { ($0.index ?? -1) == index }
        }
        func activeVideoSegments(at absoluteSeconds: Double) -> [VisibleFrameIndex.VideoSegment] {
            manifest.videoSegments.filter {
                absoluteSeconds >= $0.timelineStartSeconds && absoluteSeconds < $0.timelineEndSeconds
            }
        }
        let absolute = manifest.timeline.startSeconds + previewPositionSeconds
        let frameEpsilon = max(manifest.timeline.frameDurationSeconds / 1000.0, 0.000001)
        let frameIndex = max(0, Int(((previewPositionSeconds + frameEpsilon) / manifest.timeline.frameDurationSeconds).rounded(.down)))
        let frameSample = exactSample(frame: frameIndex)
        let sourceFrameSample = frameSample
        let sourceRelativeSeconds = sourceFrameSample.map {
            max(0, min(manifest.timeline.durationSeconds, $0.timelineSeconds - manifest.timeline.startSeconds))
        } ?? previewPositionSeconds
        let sourceAbsolute = manifest.timeline.startSeconds + sourceRelativeSeconds
        let segment = videoSegment(at: absolute)
        let sourceSegment = videoSegment(at: sourceAbsolute) ?? segment
        let frameSampleSegment = videoSegment(index: frameSample?.segmentIndex) ?? segment
        let sourceFrameSampleSegment = videoSegment(index: sourceFrameSample?.segmentIndex) ?? sourceSegment ?? frameSampleSegment
        let title = manifest.vfxTitles
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .last
        let roles = Array(Set(manifest.audioRoles
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .map(\.role)))
            .sorted()
        let sampledLayers = (sourceFrameSample?.visibleLayers ?? []).compactMap { layer -> BurnInLayerSnapshot? in
            let layerSegment = videoSegment(index: layer.segmentIndex)
            let filename = nonEmpty(layer.sourceFilename) ?? nonEmpty(layerSegment?.sourceFilename)
            guard let filename else { return nil }
            return BurnInLayerSnapshot(
                layerIndex: layer.layerIndex,
                clipName: nonEmpty(layer.clipName) ?? nonEmpty(layerSegment?.clipName),
                sourceFilename: filename,
                sourceName: nonEmpty(layer.sourceName) ?? nonEmpty(layerSegment?.sourceName),
                sourceSeconds: layer.sourceSeconds,
                sourceFrameDuration: layer.sourceFrameDuration ?? layerSegment?.sourceFrameDuration ?? manifest.timeline.frameDurationSeconds,
                sourceFrameRate: nonEmpty(layer.sourceFrameRate) ?? nonEmpty(layerSegment?.sourceFrameRate),
                sourceTcFormat: nonEmpty(layer.sourceTcFormat) ?? nonEmpty(layerSegment?.sourceTcFormat) ?? manifest.timeline.tcFormat,
                layerRole: nonEmpty(layer.layerRole) ?? nonEmpty(layerSegment?.layerRole) ?? "primary",
                timelineLane: nonEmpty(layer.timelineLane) ?? nonEmpty(layerSegment?.timelineLane),
                nestingDepth: layer.nestingDepth ?? layerSegment?.nestingDepth ?? 0,
                metadata: layer.metadata ?? layerSegment?.metadata
            )
        }
        func compactSourceLayers(_ layers: [BurnInLayerSnapshot]) -> [BurnInLayerSnapshot] {
            var seen = Set<String>()
            return layers.filter { layer in
                let key = [
                    layer.sourceFilename,
                    String(format: "%.3f", layer.sourceSeconds),
                ].joined(separator: "\u{1F}")
                return seen.insert(key).inserted
            }
        }
        func isConnectedTimelineLayer(role: String?, lane: String?) -> Bool {
            guard nonEmpty(role) == "connected", let lane = nonEmpty(lane) else { return false }
            if let numericLane = Double(lane), abs(numericLane) < 0.0001 { return false }
            return true
        }
        let fallbackSourceLayer: [BurnInLayerSnapshot] = {
            guard let layer = sourceSegment else { return [] }
            let timelineSpan = max(layer.timelineEndSeconds - layer.timelineStartSeconds, 0)
            guard timelineSpan > 0 else { return [] }
            let ratio = (sourceAbsolute - layer.timelineStartSeconds) / timelineSpan
            return [
                BurnInLayerSnapshot(
                    layerIndex: 0,
                    clipName: nonEmpty(layer.clipName),
                    sourceFilename: layer.sourceFilename,
                    sourceName: nonEmpty(layer.sourceName),
                    sourceSeconds: layer.sourceInSeconds + ((layer.sourceOutSeconds - layer.sourceInSeconds) * ratio),
                    sourceFrameDuration: layer.sourceFrameDuration,
                    sourceFrameRate: nonEmpty(layer.sourceFrameRate),
                    sourceTcFormat: nonEmpty(layer.sourceTcFormat) ?? manifest.timeline.tcFormat,
                    layerRole: nonEmpty(layer.layerRole) ?? "primary",
                    timelineLane: nonEmpty(layer.timelineLane),
                    nestingDepth: layer.nestingDepth ?? 0,
                    metadata: layer.metadata
                )
            ]
        }()
        let activePrimarySegments = activeVideoSegments(at: sourceAbsolute)
            .filter { nonEmpty($0.layerRole) != "connected" }
        let activeConnectedSegments = activeVideoSegments(at: sourceAbsolute)
            .filter { isConnectedTimelineLayer(role: $0.layerRole, lane: $0.timelineLane) }
        func layerSnapshot(for layer: VisibleFrameIndex.VideoSegment, layerIndex: Int) -> BurnInLayerSnapshot? {
            let timelineSpan = max(layer.timelineEndSeconds - layer.timelineStartSeconds, 0)
            guard timelineSpan > 0 else { return nil }
            let ratio = (sourceAbsolute - layer.timelineStartSeconds) / timelineSpan
            return BurnInLayerSnapshot(
                layerIndex: layerIndex,
                clipName: nonEmpty(layer.clipName),
                sourceFilename: layer.sourceFilename,
                sourceName: nonEmpty(layer.sourceName),
                sourceSeconds: layer.sourceInSeconds + ((layer.sourceOutSeconds - layer.sourceInSeconds) * ratio),
                sourceFrameDuration: layer.sourceFrameDuration,
                sourceFrameRate: nonEmpty(layer.sourceFrameRate),
                sourceTcFormat: nonEmpty(layer.sourceTcFormat) ?? manifest.timeline.tcFormat,
                layerRole: nonEmpty(layer.layerRole) ?? "primary",
                timelineLane: nonEmpty(layer.timelineLane),
                nestingDepth: layer.nestingDepth ?? 0,
                metadata: layer.metadata
            )
        }
        let primarySourceLayer = sampledLayers.last(where: { $0.layerRole != "connected" })
            ?? activePrimarySegments.last.flatMap { layerSnapshot(for: $0, layerIndex: 0) }
            ?? fallbackSourceLayer.first
        let sampledConnectedLayers = sampledLayers.filter { isConnectedTimelineLayer(role: $0.layerRole, lane: $0.timelineLane) }
        let fallbackConnectedLayers = activeConnectedSegments.enumerated().compactMap { index, layer in
            layerSnapshot(for: layer, layerIndex: index)
        }
        func layerLaneRank(_ layer: BurnInLayerSnapshot) -> Double {
            Double(layer.timelineLane ?? "") ?? 0
        }
        func orderedConnectedLayers(_ layers: [BurnInLayerSnapshot]) -> [BurnInLayerSnapshot] {
            layers.sorted {
                let leftLane = layerLaneRank($0)
                let rightLane = layerLaneRank($1)
                if leftLane != rightLane { return leftLane > rightLane }
                if $0.nestingDepth != $1.nestingDepth { return $0.nestingDepth > $1.nestingDepth }
                return $0.layerIndex < $1.layerIndex
            }
        }
        let requestedSourceLayers = orderedConnectedLayers(
            compactSourceLayers(sampledConnectedLayers.isEmpty ? fallbackConnectedLayers : sampledConnectedLayers)
        )
        let sourceLayers = snapshot.sourceLayerLimit <= 0
            ? []
            : Array(requestedSourceLayers.prefix(min(snapshot.sourceLayerLimit, 6)))
        let visibleOwnerNames = Set(
            ([
                primarySourceLayer?.clipName,
                Optional(primarySourceLayer?.sourceFilename ?? ""),
                primarySourceLayer?.sourceName,
                sourceFrameSample?.clipName ?? sourceFrameSampleSegment?.clipName,
                sourceFrameSample?.sourceFilename ?? sourceFrameSampleSegment?.sourceFilename,
                sourceFrameSample?.sourceName ?? sourceFrameSampleSegment?.sourceName,
                sourceSegment?.clipName,
                sourceSegment?.sourceFilename,
                sourceSegment?.sourceName,
            ] + sourceLayers.flatMap { layer in
                [
                    layer.clipName,
                    Optional(layer.sourceFilename),
                    layer.sourceName,
                ]
            })
            .compactMap { ownerAlias($0) }
        )
        var seenAnalysisItems = Set<String>()
        let activeAnalysis = (manifest.analysisItems ?? [])
            .filter { absolute >= $0.timelineStartSeconds && absolute < $0.timelineEndSeconds }
            .filter { item in
                guard !visibleOwnerNames.isEmpty else { return false }
                let owner = ownerAlias(item.owner)
                let ownerName = ownerAlias(item.ownerName)
                return owner.map { visibleOwnerNames.contains($0) } == true
                    || ownerName.map { visibleOwnerNames.contains($0) } == true
            }
            .filter { item in
                let detailKey = Self.analysisDetailKind(for: item.key)?.rawValue ?? item.key ?? item.label
                let ownerKey = detailKey == BurnInAnalysisDetail.spatialConform.rawValue
                    ? ""
                    : ownerAlias(item.ownerName) ?? ownerAlias(item.owner) ?? ""
                let key = [
                    detailKey,
                    item.label,
                    item.value ?? "",
                    ownerKey,
                ].joined(separator: "\u{1F}")
                return seenAnalysisItems.insert(key).inserted
            }
        let analysisFlags = Array(Set(activeAnalysis.map { $0.label })).sorted().joined(separator: ", ")
        let analysisEffects = Array(Set(activeAnalysis
            .filter { !($0.key ?? "").hasPrefix("transform") }
            .map { $0.label }))
            .sorted()
            .joined(separator: ", ")
        let analysisTransform = activeAnalysis
            .filter { ($0.key ?? "").hasPrefix("transform") }
            .map { item in
                let label = item.label.replacingOccurrences(of: "Transform ", with: "")
                if let value = item.value, !value.isEmpty {
                    return "\(label): \(value)"
                }
                return label
            }
            .joined(separator: ", ")
        let analysisTransformPosition = activeAnalysis
            .first(where: { $0.key == "transform_position" })?
            .value ?? ""
        let analysisTransformScale = activeAnalysis
            .first(where: { $0.key == "transform_scale" })?
            .value ?? ""
        let analysisTransformRotation = activeAnalysis
            .first(where: { $0.key == "transform_rotation" })?
            .value ?? ""
        func firstAnalysisValue(_ key: String) -> String {
            activeAnalysis.first(where: { $0.key == key })?.value ?? ""
        }
        func firstAnalysisValue(_ key: String, for layer: BurnInLayerSnapshot) -> String {
            let aliases = Set([
                ownerAlias(layer.clipName),
                ownerAlias(layer.sourceFilename),
                ownerAlias(layer.sourceName),
            ].compactMap { $0 })
            guard !aliases.isEmpty else { return "" }
            return activeAnalysis.first { item in
                item.key == key
                    && (
                        ownerAlias(item.owner).map { aliases.contains($0) } == true
                        || ownerAlias(item.ownerName).map { aliases.contains($0) } == true
                    )
            }?.value ?? ""
        }
        let analysisCrop = firstAnalysisValue("crop")
        let analysisDistort = firstAnalysisValue("distort")
        let analysisSpatialConform = firstAnalysisValue("spatial_conform")
        let analysisConformRate = firstAnalysisValue("conform_rate")
        let analysisRetime = firstAnalysisValue("retime")
        let analysisStabilization = firstAnalysisValue("stabilization")
        let analysisOpticalFlow = firstAnalysisValue("optical_flow")
        var seenAnalysisDetails = Set<String>()
        let analysisDetails = activeAnalysis
            .filter { item in
                guard let detail = Self.analysisDetailKind(for: item.key) else { return true }
                return snapshot.analysisDetailOptions[detail.rawValue] ?? true
            }
            .compactMap { item -> String? in
                let label = Self.displayAnalysisLabel(item.label)
                let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detailKey = Self.analysisDetailKind(for: item.key)?.rawValue ?? item.key ?? label
                let key = [detailKey, label, value].joined(separator: "\u{1F}")
                guard seenAnalysisDetails.insert(key).inserted else { return nil }
                if !value.isEmpty {
                    return "\(label): \(value)"
                }
                return label
            }
            .joined(separator: "\n")
        let sourceSeconds: Double? = sourceSegment.map {
            let timelineSpan = max($0.timelineEndSeconds - $0.timelineStartSeconds, 0)
            guard timelineSpan > 0 else { return $0.sourceInSeconds }
            let ratio = (sourceAbsolute - $0.timelineStartSeconds) / timelineSpan
            return $0.sourceInSeconds + (($0.sourceOutSeconds - $0.sourceInSeconds) * ratio)
        }
        let resolvedSourceSeconds = primarySourceLayer?.sourceSeconds
            ?? sourceFrameSample?.sourceSeconds
            ?? sourceSeconds
        let resolvedSourceFrameDuration = primarySourceLayer?.sourceFrameDuration
            ?? sourceFrameSample?.sourceFrameDuration
            ?? sourceSegment?.sourceFrameDuration
            ?? manifest.timeline.frameDurationSeconds
        let resolvedSourceTcFormat = primarySourceLayer?.sourceTcFormat
            ?? sourceFrameSample?.sourceTcFormat
            ?? sourceSegment?.sourceTcFormat
            ?? ""
        let resolvedSourceFrameRate = primarySourceLayer?.sourceFrameRate
            ?? sourceFrameSample?.sourceFrameRate
            ?? sourceFrameSampleSegment?.sourceFrameRate
            ?? sourceSegment?.sourceFrameRate
            ?? ""
        let resolvedSourceMetadata = primarySourceLayer?.metadata
            ?? sourceFrameSample?.metadata
            ?? sourceFrameSampleSegment?.metadata
            ?? sourceSegment?.metadata
        func metadataID(_ entry: VisibleFrameIndex.BurnInMetadata.Entry) -> String {
            let key = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return key.isEmpty ? entry.label : key
        }
        func metadataSelectionID(_ entry: VisibleFrameIndex.BurnInMetadata.Entry) -> String {
            entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func metadataGroupID(_ entry: VisibleFrameIndex.BurnInMetadata.Entry) -> String {
            entry.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        func metadataValueLooksLikeFilename(_ value: String) -> Bool {
            let lower = value.lowercased()
            if lower.hasSuffix(".mov") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mxf") { return true }
            if value.range(of: #"_[0-9]{6}_[0-9]{6}"#, options: .regularExpression) != nil { return true }
            return value.range(of: #"[A-Z]_[0-9]{4}[A-Z][0-9]{3}"#, options: .regularExpression) != nil
        }
        func metadataPreferenceScore(_ entry: VisibleFrameIndex.BurnInMetadata.Entry) -> Int {
            let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = normalizeMetadataSource(entry.source)
            var score = 0
            if source.contains("custom") { score += 60 }
            if source.contains("asset") { score += 20 }
            if metadataValueLooksLikeFilename(value) { score -= 80 }
            if value.range(of: #"[0-9]{2}-[0-9]{2}-[0-9]{4}"#, options: .regularExpression) != nil { score -= 12 }
            if value.count <= 12 { score += 12 }
            if ["reel", "scene", "shot", "take"].contains(label), value.count <= 8 { score += 10 }
            score -= min(30, value.count / 3)
            return score
        }
        func collapseMetadataEntries(_ entries: [VisibleFrameIndex.BurnInMetadata.Entry]) -> [VisibleFrameIndex.BurnInMetadata.Entry] {
            var collapsed: [VisibleFrameIndex.BurnInMetadata.Entry] = []
            var indexByGroup: [String: Int] = [:]
            for entry in entries {
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let groupID = metadataGroupID(entry)
                guard !groupID.isEmpty else { continue }
                if let existingIndex = indexByGroup[groupID] {
                    let existing = collapsed[existingIndex]
                    if metadataPreferenceScore(entry) > metadataPreferenceScore(existing) {
                        collapsed[existingIndex] = entry
                    }
                } else {
                    indexByGroup[groupID] = collapsed.count
                    collapsed.append(entry)
                }
            }
            return collapsed
        }
        func selectedMetadataText(from metadata: VisibleFrameIndex.BurnInMetadata?) -> String {
            let entries = metadata?.entries ?? []
            let selected = entries.filter {
                (snapshot.metadataSelections[metadataID($0)] ?? false)
                    || (snapshot.metadataSelections[metadataSelectionID($0)] ?? false)
            }
            let hasExplicitSelections = snapshot.metadataSelections.values.contains(true)
            let source: [VisibleFrameIndex.BurnInMetadata.Entry]
            if hasExplicitSelections {
                source = selected
            } else {
                let customEntries = entries.filter { normalizeMetadataSource($0.source).contains("custom") }
                source = customEntries.isEmpty ? entries : customEntries
            }
            let rendered = collapseMetadataEntries(source)
                .map { "\($0.label): \($0.value)" }
                .joined(separator: " | ")
            if hasExplicitSelections {
                return rendered
            }
            return rendered.isEmpty ? (metadata?.custom ?? "") : rendered
        }
        func displayFilename(_ filename: String) -> String {
            guard !filename.isEmpty, !snapshot.showFileExtensions else { return filename }
            return (filename as NSString).deletingPathExtension
        }
        func labeled(_ token: String, _ label: String, _ value: String) -> String {
            guard !value.isEmpty else { return "" }
            return (snapshot.labelOverrides[token] ?? snapshot.showLabels) ? "\(label): \(value)" : value
        }
        func layerDetailEnabled(_ detail: BurnInSourceLayerDetail) -> Bool {
            snapshot.sourceLayerDetailOptions[detail.rawValue] ?? Self.defaultBurnInSourceLayerDetailOptions()[detail.rawValue] ?? false
        }
        func layerDetailLabelsVisible() -> Bool {
            snapshot.labelOverrides["source_layers_details"]
                ?? snapshot.labelOverrides["source_layers"]
                ?? snapshot.showLabels
        }
        func layerDetailLabel(_ label: String, _ value: String) -> String {
            layerDetailLabelsVisible() ? "\(label): \(value)" : value
        }
        func sourceFrameText(seconds: Double, frameDuration: Double) -> String {
            let duration = max(frameDuration, 0.000001)
            return String(max(0, Int((seconds / duration).rounded(.down))))
        }
        func layerFPSValue(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return "" }
            return trimmed.localizedCaseInsensitiveContains("fps") ? trimmed : "\(trimmed) fps"
        }
        func sourceLayerDetailsText(alwaysDetailed: Bool) -> String {
            sourceLayers
                .enumerated()
                .compactMap { index, layer in
                    let tc = formatTimecode(
                        seconds: layer.sourceSeconds,
                        frameDuration: layer.sourceFrameDuration,
                        tcFormat: layer.sourceTcFormat
                    )
                    let metadata = layer.metadata
                    let detailParts: [(BurnInSourceLayerDetail, String, String)] = [
                        (.sourceFilename, "File", displayFilename(layer.sourceFilename)),
                        (.sourceTC, "TC", tc),
                        (.sourceFrame, "Frame", sourceFrameText(seconds: layer.sourceSeconds, frameDuration: layer.sourceFrameDuration)),
                        (.sourceFPS, "FPS", layerFPSValue(layer.sourceFrameRate)),
                        (.clipName, "Clip", displayFilename(nonEmpty(layer.clipName) ?? "")),
                        (.sourceName, "Source", displayFilename(nonEmpty(layer.sourceName) ?? "")),
                        (.reel, "Reel", metadata?.reel ?? ""),
                        (.scene, "Scene", metadata?.scene ?? ""),
                        (.take, "Take", metadata?.take ?? ""),
                        (.cameraName, "Camera", metadata?.camera ?? ""),
                        (.angle, "Angle", metadata?.angle ?? ""),
                        (.customMetadata, "Metadata", selectedMetadataText(from: metadata)),
                        (.retime, "Retime", firstAnalysisValue("retime", for: layer)),
                    ]
                    let selected = detailParts.compactMap { detail, label, value -> String? in
                        guard layerDetailEnabled(detail) else { return nil }
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return nil }
                        return layerDetailLabel(label, trimmed)
                    }
                    guard !selected.isEmpty else { return nil }
                    if alwaysDetailed {
                        let linePrefix = "L\(index + 1):"
                        switch snapshot.sourceLayerDetailLayout {
                        case .oneLine:
                            return "\(linePrefix) \(selected.joined(separator: "   "))"
                        case .twoLines:
                            guard selected.count > 1 else { return "\(linePrefix) \(selected[0])" }
                            return "\(linePrefix) \(selected[0])\n    \(selected.dropFirst().joined(separator: "   "))"
                        }
                    }
                    return "L\(index + 1): \(displayFilename(layer.sourceFilename))"
                }
                .joined(separator: "\n")
        }
        let sourceLayersDetailText = sourceLayerDetailsText(alwaysDetailed: true)
        let sourceLayersText = snapshot.sourceLayerDisplayMode == .detailed
            ? sourceLayersDetailText
            : sourceLayers
                .enumerated()
                .map { index, layer in
                    "L\(index + 1): \(displayFilename(layer.sourceFilename))"
                }
                .joined(separator: "\n")
        let sourceLayersTCText = sourceLayers
            .enumerated()
            .map { index, layer in
                let tc = formatTimecode(
                    seconds: layer.sourceSeconds,
                    frameDuration: layer.sourceFrameDuration,
                    tcFormat: layer.sourceTcFormat
                )
                return "L\(index + 1): \(displayFilename(layer.sourceFilename))  \(labeled("source_layers_tc", "SrcTC", tc))"
            }
            .joined(separator: "\n")
        let sourceFilename = displayFilename(
            nonEmpty(primarySourceLayer?.sourceFilename)
                ?? nonEmpty(sourceFrameSample?.sourceFilename)
                ?? nonEmpty(sourceSegment?.sourceFilename)
                ?? ""
        )
        let clipName = displayFilename(
            nonEmpty(primarySourceLayer?.clipName)
                ?? nonEmpty(sourceFrameSample?.clipName)
                ?? nonEmpty(sourceSegment?.clipName)
                ?? ""
        )
        let sourceName = displayFilename(
            nonEmpty(primarySourceLayer?.sourceName)
                ?? nonEmpty(sourceFrameSample?.sourceName)
                ?? nonEmpty(sourceSegment?.sourceName)
                ?? ""
        )
        let sourceTC = resolvedSourceSeconds.map { formatTimecode(seconds: $0, frameDuration: resolvedSourceFrameDuration, tcFormat: resolvedSourceTcFormat) } ?? ""
        let sourceFrameDurationForDisplay = max(resolvedSourceFrameDuration, 0.000001)
        let sourceFrame = resolvedSourceSeconds.map { String(max(0, Int(($0 / sourceFrameDurationForDisplay).rounded(.down)))) } ?? ""
        func fpsValue(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return "" }
            return trimmed.localizedCaseInsensitiveContains("fps") ? trimmed : "\(trimmed) fps"
        }
        let values: [String: String] = [
            "project": labeled("project", "Project", manifest.project),
            "event": labeled("event", "Event", manifest.event),
            "timeline_tc": labeled("timeline_tc", "Timeline TC", formatTimecode(seconds: absolute, frameDuration: manifest.timeline.frameDurationSeconds, tcFormat: manifest.timeline.tcFormat)),
            "timeline_frame": labeled("timeline_frame", "Timeline Frame", String(frameIndex)),
            "timeline_fps": labeled("timeline_fps", "Timeline FPS", fpsValue(manifest.timeline.frameRate)),
            "source_file": labeled("source_file", "File", sourceFilename),
            "source_fps": labeled("source_fps", "FPS", fpsValue(resolvedSourceFrameRate)),
            "source_tc": labeled("source_tc", "SrcTC", sourceTC),
            "source_frame": labeled("source_frame", "Source Frame", sourceFrame),
            "clip_name": labeled("clip_name", "Clip", clipName),
            "source_name": labeled("source_name", "Source", sourceName),
            "source_reel": labeled("source_reel", "Reel", resolvedSourceMetadata?.reel ?? ""),
            "source_scene": labeled("source_scene", "Scene", resolvedSourceMetadata?.scene ?? ""),
            "source_take": labeled("source_take", "Take", resolvedSourceMetadata?.take ?? ""),
            "source_camera": labeled("source_camera", "Camera", resolvedSourceMetadata?.camera ?? ""),
            "source_angle": labeled("source_angle", "Angle", resolvedSourceMetadata?.angle ?? ""),
            "metadata_custom": labeled("metadata_custom", "Metadata", selectedMetadataText(from: resolvedSourceMetadata)),
            "metadata_all": labeled("metadata_all", "Metadata", resolvedSourceMetadata?.all ?? ""),
            "source_layers": sourceLayersText,
            "source_layers_tc": sourceLayersTCText,
            "source_layers_details": sourceLayersDetailText,
            "vfx_number": labeled("vfx_number", "VFX", title?.vfxNumber ?? ""),
            "vfx_note": labeled("vfx_note", "Note", title?.note ?? ""),
            "audio_role": labeled("audio_role", "Audio", roles.joined(separator: ", ")),
            "analysis_flags": labeled("analysis_flags", "Analysis", analysisFlags),
            "analysis_effects": labeled("analysis_effects", "Effects", analysisEffects),
            "analysis_transform": labeled("analysis_transform", "Transform", analysisTransform),
            "analysis_transform_position": labeled("analysis_transform_position", "Pos", analysisTransformPosition),
            "analysis_transform_scale": labeled("analysis_transform_scale", "Scale", analysisTransformScale),
            "analysis_transform_rotation": labeled("analysis_transform_rotation", "Rot", analysisTransformRotation),
            "analysis_crop": labeled("analysis_crop", "Crop", analysisCrop),
            "analysis_distort": labeled("analysis_distort", "Distort", analysisDistort),
            "analysis_spatial_conform": labeled("analysis_spatial_conform", "Conform", analysisSpatialConform),
            "analysis_conform_rate": labeled("analysis_conform_rate", "Rate", analysisConformRate),
            "analysis_retime": labeled("analysis_retime", "Retime", analysisRetime),
            "analysis_stabilization": labeled("analysis_stabilization", "Stabilize", analysisStabilization),
            "analysis_optical_flow": labeled("analysis_optical_flow", "Optical Flow", analysisOpticalFlow),
            "analysis_details": analysisDetails,
        ]
        var rendered = field.template
        for (token, value) in values {
            rendered = rendered.replacingOccurrences(of: "{\(token)}", with: value)
        }
        func conditionHaystack(for subject: BurnInCondition.Subject) -> String {
            switch subject {
            case .audioRole:
                roles.joined(separator: "\n")
            case .sourceFile:
                [
                    sourceFilename,
                    clipName,
                    sourceName,
                    sourceLayers.map(\.sourceFilename).joined(separator: "\n"),
                ].joined(separator: "\n")
            case .vfxNumber:
                title?.vfxNumber ?? ""
            case .vfxNote:
                title?.note ?? ""
            case .analysis:
                [
                    analysisFlags,
                    analysisEffects,
                    analysisTransform,
                    analysisDetails,
                ].joined(separator: "\n")
            }
        }
        let wantsConditionalText = rendered.contains("{custom_text}")
        guard wantsConditionalText else { return rendered }
        let conditionalText = snapshot.conditions.compactMap { condition -> String? in
            let needle = condition.contains.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = condition.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, !message.isEmpty else { return nil }
            let haystack = conditionHaystack(for: condition.subject)
            guard haystack.localizedCaseInsensitiveContains(needle) else { return nil }
            var resolvedMessage = message
            for (token, value) in values {
                resolvedMessage = resolvedMessage.replacingOccurrences(of: "{\(token)}", with: value)
            }
            return resolvedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return rendered.replacingOccurrences(of: "{custom_text}", with: conditionalText)
    }

    var selectedBurnInFieldIndex: Int {
        burnInFields.firstIndex(where: { $0.anchor == selectedBurnInAnchor }) ?? 0
    }

    static func defaultBurnInStyle() -> BurnInStyle {
        BurnInStyle(
            fontSize: 20,
            horizontalPadding: 48,
            verticalPadding: 36,
            textColor: .white,
            textColorValue: .preset(.white),
            textOpacity: 1,
            backgroundOpacity: 0.35
        )
    }

    static func defaultBurnInAnalysisDetailOptions() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: BurnInAnalysisDetail.allCases.map { ($0.rawValue, true) })
    }

    nonisolated static func defaultBurnInSourceLayerDetailOptions() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: BurnInSourceLayerDetail.allCases.map { detail in
            let enabled = switch detail {
            case .sourceFilename, .sourceTC, .retime: true
            default: false
            }
            return (detail.rawValue, enabled)
        })
    }

    func burnInAnalysisDetailEnabled(_ detail: BurnInAnalysisDetail) -> Bool {
        burnInAnalysisDetailOptions[detail.rawValue] ?? true
    }

    func setBurnInAnalysisDetailEnabled(_ enabled: Bool, for detail: BurnInAnalysisDetail) {
        burnInAnalysisDetailOptions[detail.rawValue] = enabled
    }

    func burnInSourceLayerDetailEnabled(_ detail: BurnInSourceLayerDetail) -> Bool {
        burnInSourceLayerDetailOptions[detail.rawValue] ?? Self.defaultBurnInSourceLayerDetailOptions()[detail.rawValue] ?? false
    }

    func setBurnInSourceLayerDetailEnabled(_ enabled: Bool, for detail: BurnInSourceLayerDetail) {
        burnInSourceLayerDetailOptions[detail.rawValue] = enabled
    }

    struct BurnInMetadataOption: Identifiable, Hashable {
        let id: String
        let label: String
        let source: String
    }

    var burnInMetadataOptions: [BurnInMetadataOption] {
        var options: [BurnInMetadataOption] = []
        var seen = Set<String>()
        func append(_ entries: [VisibleFrameIndex.BurnInMetadata.Entry]?) {
            for entry in entries ?? [] {
                let id = metadataID(for: entry)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                options.append(BurnInMetadataOption(
                    id: id,
                    label: entry.label,
                    source: entry.source ?? ""
                ))
            }
        }
        visibleFrameIndex?.videoSegments.forEach { append($0.metadata?.entries) }
        return options.sorted { lhs, rhs in
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    func burnInMetadataEnabled(id: String) -> Bool {
        burnInMetadataSelections[id] ?? false
    }

    func setBurnInMetadataEnabled(_ enabled: Bool, id: String) {
        burnInMetadataSelections[id] = enabled
    }

    private func metadataID(for entry: VisibleFrameIndex.BurnInMetadata.Entry) -> String {
        entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizeMetadataSource(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func analysisDetailKind(for key: String?) -> BurnInAnalysisDetail? {
        switch key {
        case "transform_position": .position
        case "transform_scale": .scale
        case "transform_rotation": .rotation
        case "transform": .transform
        case let value where value?.hasPrefix("transform") == true: .transform
        case "crop": .crop
        case "distort": .distort
        case "spatial_conform": .spatialConform
        case "retime": .retime
        case "stabilization": .stabilize
        case "optical_flow": .opticalFlow
        default: nil
        }
    }

    nonisolated private static func displayAnalysisLabel(_ label: String) -> String {
        label.replacingOccurrences(
            of: #"\s+\([^)]*\.[A-Za-z0-9]{2,8}\)"#,
            with: "",
            options: .regularExpression
        )
    }

    func effectiveBurnInStyle(for field: BurnInField) -> BurnInStyle {
        if field.usesGlobalStyle { return burnInGlobalStyle }
        return BurnInStyle(
            fontSize: field.fontSize,
            horizontalPadding: field.horizontalPadding,
            verticalPadding: field.verticalPadding,
            textColor: field.textColor,
            textColorValue: field.textColorValue ?? burnInGlobalStyle.textColorValue,
            textOpacity: field.textOpacity,
            backgroundOpacity: field.backgroundOpacity
        )
    }

    nonisolated private static func effectiveBurnInStyle(for field: BurnInField, snapshot: BurnInRenderSnapshot) -> BurnInStyle {
        if field.usesGlobalStyle { return snapshot.globalStyle }
        return BurnInStyle(
            fontSize: field.fontSize,
            horizontalPadding: field.horizontalPadding,
            verticalPadding: field.verticalPadding,
            textColor: field.textColor,
            textColorValue: field.textColorValue ?? snapshot.globalStyle.textColorValue,
            textOpacity: field.textOpacity,
            backgroundOpacity: field.backgroundOpacity
        )
    }

    static func defaultBurnInFields() -> [BurnInField] {
        let style = defaultBurnInStyle()
        return BurnInAnchor.allCases.map { anchor in
            let template: String
            switch anchor {
            case .topLeft: template = "{project}"
            case .topRight: template = "{timeline_tc}"
            case .bottomLeft: template = "{source_file}\n{source_tc}"
            case .bottomRight: template = "{vfx_number}"
            default: template = ""
            }
            return BurnInField(
                anchor: anchor,
                enabled: !template.isEmpty,
                template: template,
                usesGlobalStyle: true,
                fontSize: style.fontSize,
                horizontalPadding: style.horizontalPadding,
                verticalPadding: style.verticalPadding,
                textColor: style.textColor,
                textColorValue: style.textColorValue,
                textOpacity: style.textOpacity,
                backgroundOpacity: style.backgroundOpacity
            )
        }
    }

    var dropTypeIdentifiers: [String] {
        [UTType.fileURL.identifier] + finalCutPasteboardTypes
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose an FCPXML file or bundle"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        // FCPXMLD is a filesystem directory package. AppKit requires directory
        // selection even when the package is presented as a single file.
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url: url)
    }

    func chooseBurnInVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video to Burn In"
        panel.message = "Choose a reference or master video. Leave this empty to render a transparent ProRes 4444 overlay later."
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        burnInVideoURL = url
    }

    func clearBurnInVideo() {
        burnInVideoURL = nil
    }

    func normalizeBurnInExportSettings() {
        if burnInExportMode == .transparentOverlay {
            burnInExportCodec = .proRes4444
            burnInExportContainer = .mov
            return
        }
        if !Self.BurnInExportCodec.burnedInReleaseCodecs.contains(burnInExportCodec) {
            burnInExportCodec = .h264
        }
    }

    func prepareBurnInVideoExport() {
        normalizeBurnInExportSettings()
        if burnInExportMode == .transparentOverlay {
            let name = "\(visibleFrameIndex?.project ?? "Turnover")-BurnIn-Overlay.mov"
            let directory = burnInVideoURL?.deletingLastPathComponent() ?? sourceURL?.deletingLastPathComponent()
            guard let destination = chooseBurnInVideoExportURL(
                defaultName: name,
                directory: directory,
                codec: .proRes4444
            ) else { return }
            exportTransparentBurnInOverlay(destination: destination)
            return
        }
        guard let source = burnInVideoURL else {
            let alert = NSAlert()
            alert.messageText = "Choose a video first"
            alert.informativeText = "Transparent overlay export is locked to ProRes 4444, but the standalone renderer still needs the video render path. Choose a reference video to export a burned-in file now."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        guard Self.BurnInExportCodec.burnedInReleaseCodecs.contains(burnInExportCodec) else {
            let alert = NSAlert()
            alert.messageText = "Choose H.264 or HEVC"
            alert.informativeText = "ProRes burned-in export is disabled for this release while audio handling is being reworked. Transparent Overlay still exports ProRes 4444."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        guard let destination = chooseBurnInVideoExportURL(source: source) else { return }
        exportBurnInVideo(source: source, destination: destination)
    }

    private func chooseBurnInVideoExportURL(source: URL) -> URL? {
        let container = Self.effectiveBurnInExportContainer(codec: burnInExportCodec, requested: burnInExportContainer)
        return chooseBurnInVideoExportURL(
            defaultName: "\(source.deletingPathExtension().lastPathComponent)-BurnIn.\(Self.exportFileExtension(codec: burnInExportCodec, container: container))",
            directory: source.deletingLastPathComponent(),
            codec: burnInExportCodec,
            container: container
        )
    }

    private func chooseBurnInVideoExportURL(
        defaultName: String,
        directory: URL?,
        codec: BurnInExportCodec,
        container: BurnInExportContainer? = nil
    ) -> URL? {
        let panel = NSSavePanel()
        let fileType = Self.exportFileType(codec: codec, container: container ?? Self.effectiveBurnInExportContainer(codec: codec, requested: burnInExportContainer))
        panel.title = "Export Burn-In Video"
        panel.prompt = "Export"
        panel.allowedContentTypes = fileType == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let fileExtension = Self.exportFileExtension(
            codec: codec,
            container: container ?? Self.effectiveBurnInExportContainer(codec: codec, requested: burnInExportContainer)
        )
        return url.pathExtension.isEmpty ? url.appendingPathExtension(fileExtension) : url
    }

    private func exportBurnInVideo(source: URL, destination: URL) {
        saveSelectedBurnInPreset()
        guard let snapshot = currentBurnInRenderSnapshot() else {
            state = .failed("Build the Burn-In cache before exporting.")
            log = "Build the Burn-In cache before exporting."
            return
        }
        guard Self.BurnInExportCodec.burnedInReleaseCodecs.contains(snapshot.exportCodec) else {
            state = .failed("ProRes burned-in export is disabled for this release.")
            log = "Use H.264 or HEVC for burned-in reference exports. Transparent Overlay still exports ProRes 4444."
            return
        }
        guard preflightBurnInExport(destination: destination, snapshot: snapshot, needsAudioMux: false) else { return }
        let job = BurnInExportJob(id: UUID(), kind: .burnedInVideo(source: source), destination: destination, snapshot: snapshot)
        enqueueOrStartBurnInExport(job)
    }

    private func exportTransparentBurnInOverlay(destination: URL) {
        saveSelectedBurnInPreset()
        guard let snapshot = currentBurnInRenderSnapshot() else {
            state = .failed("Build the Burn-In cache before exporting a transparent overlay.")
            log = "Build the Burn-In cache before exporting a transparent overlay."
            return
        }
        guard preflightBurnInExport(destination: destination, snapshot: snapshot, needsAudioMux: false) else { return }
        let job = BurnInExportJob(id: UUID(), kind: .transparentOverlay, destination: destination, snapshot: snapshot)
        enqueueOrStartBurnInExport(job)
    }

    private func preflightBurnInExport(destination: URL, snapshot: BurnInRenderSnapshot, needsAudioMux: Bool) -> Bool {
        let width = snapshot.manifest.timeline.width ?? 1920
        let height = snapshot.manifest.timeline.height ?? 1080
        let codec: BurnInExportCodec = snapshot.exportMode == .transparentOverlay ? .proRes4444 : snapshot.exportCodec
        let estimatedBytes = Self.estimatedBurnInExportBytes(
            width: max(16, width),
            height: max(16, height),
            frameDuration: snapshot.frameDurationSeconds,
            durationSeconds: snapshot.durationSeconds,
            codec: codec,
            bitrateMbps: snapshot.exportBitrateMbps,
            needsAudioMux: needsAudioMux,
            isTransparentOverlay: snapshot.exportMode == .transparentOverlay
        )
        let space = Self.exportSpaceStatus(estimatedBytes: estimatedBytes, destination: destination, needsAudioMux: needsAudioMux)
        guard space.hasEnoughSpace else {
            let message = "Not enough disk space for this export."
            let detail = "Estimated need \(Self.formatBytes(space.requiredBytes)); available \(Self.formatBytes(space.availableBytes)). Free space or choose a different destination."
            state = .failed(message)
            log = "\(message)\n\(detail)"
            showAlert(title: message, message: detail)
            return false
        }
        return true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func burnInPresetSummariesForHeadless() -> [[String: Any]] {
        ensureBurnInPresetLibrary()
        return burnInPresets.map { preset in
            [
                "id": preset.id,
                "name": preset.name,
                "selected": preset.id == selectedBurnInPresetID,
            ]
        }
    }

    func exportTransparentBurnInHeadless(
        source: URL,
        destination: URL,
        presetID: String?,
        presetName: String?
    ) async throws -> [String: Any] {
        try applyBurnInPresetForHeadless(id: presetID, name: presetName)
        burnInExportMode = .transparentOverlay
        burnInExportCodec = .proRes4444
        burnInRevealExportWhenDone = false
        burnInExportInSeconds = nil
        burnInExportOutSeconds = nil
        try await buildBurnInManifestForHeadless(source: source)
        guard let snapshot = currentBurnInRenderSnapshot() else {
            throw NodeRunner.ProcessFailure(message: "Build the Burn-In cache before exporting a transparent overlay.")
        }
        let stats = try await Self.renderTransparentBurnInOverlay(
            destination: destination,
            snapshot: snapshot,
            progress: { frame, totalFrames, startedAt in
                if frame == 1 || frame == totalFrames || frame % 120 == 0 {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let progress = totalFrames > 0 ? Double(frame) / Double(totalFrames) : 0
                    fputs("progress \(Int(progress * 100))% frame \(frame)/\(totalFrames) elapsed \(String(format: "%.1f", elapsed))s\n", stderr)
                }
            },
            status: { message in
                fputs("\(message)\n", stderr)
            }
        )
        return [
            "status": "ok",
            "output_path": destination.path,
            "preset_id": selectedBurnInPresetID,
            "preset_name": burnInPresets.first(where: { $0.id == selectedBurnInPresetID })?.name ?? "",
            "frame_count": stats.frameCount,
            "duration_seconds": stats.timelineDurationSeconds,
            "elapsed_seconds": stats.elapsedSeconds,
            "render_fps": stats.renderFPS,
            "realtime_multiple": stats.realtimeMultiple,
            "output_bytes": stats.outputBytes,
        ]
    }

    private func applyBurnInPresetForHeadless(id: String?, name: String?) throws {
        ensureBurnInPresetLibrary()
        if let id, !id.isEmpty {
            guard burnInPresets.contains(where: { $0.id == id }) else {
                throw NodeRunner.ProcessFailure(message: "Burn-In preset ID not found: \(id)")
            }
            selectedBurnInPresetID = id
            applySelectedBurnInPreset()
            return
        }
        if let name, !name.isEmpty {
            guard let preset = burnInPresets.first(where: { $0.name == name }) else {
                throw NodeRunner.ProcessFailure(message: "Burn-In preset not found: \(name)")
            }
            selectedBurnInPresetID = preset.id
            applySelectedBurnInPreset()
            return
        }
        applySelectedBurnInPreset()
    }

    private func buildBurnInManifestForHeadless(source: URL) async throws {
        guard let nodeURL = NodeRunner.findNode() else {
            throw NodeRunner.ProcessFailure(message: "The bundled Node.js runtime is missing.")
        }
        guard let scriptURL = NodeRunner.dataBurnInIndexScript() else {
            throw NodeRunner.ProcessFailure(message: "The bundled Data Burn-In preview-cache planner is missing.")
        }
        let plannerSource = source.pathExtension.lowercased() == "fcpxmld"
            ? source.appendingPathComponent("Info.fcpxml")
            : source
        let debugFolder = try createDebugJobDirectory(tool: "Data-Burn-In-Headless")
        let destination = debugFolder.appendingPathComponent("VisibleFrameIndex.json")
        let report = debugFolder.appendingPathComponent("Report.txt")
        _ = try await Task.detached(priority: .userInitiated) {
            try await NodeRunner.run(
                executable: nodeURL,
                arguments: [
                    scriptURL.path,
                    "--source-xml", plannerSource.path,
                    "--output-index", destination.path,
                    "--report", report.path,
                ]
            )
        }.value
        let data = try Data(contentsOf: destination)
        let manifest = try JSONDecoder().decode(VisibleFrameIndex.self, from: data)
        visibleFrameIndex = manifest
        visibleFrameSamplesByFrame = Dictionary(uniqueKeysWithValues: (manifest.frameSamples ?? []).map { ($0.frame, $0) })
        burnInDurationSeconds = max(manifest.timeline.durationSeconds, 0)
        burnInPositionSeconds = 0
        sourceURL = source
        outputURL = nil
        reportURL = report
    }

    private func enqueueOrStartBurnInExport(_ job: BurnInExportJob) {
        guard burnInExportTask == nil else {
            burnInExportQueue.append(job)
            refreshBurnInExportQueueState()
            log = "Queued Data Burn-In export: \(job.destination.lastPathComponent)"
            return
        }
        startBurnInExport(job)
    }

    private func startNextBurnInExportIfNeeded() {
        guard burnInExportTask == nil, !burnInExportQueue.isEmpty else {
            refreshBurnInExportQueueState()
            return
        }
        let next = burnInExportQueue.removeFirst()
        refreshBurnInExportQueueState()
        startBurnInExport(next)
    }

    private func startBurnInExport(_ job: BurnInExportJob) {
        state = .running
        log = "Exporting Data Burn-In video..."
        shouldOpenBurnInCustomizerAfterBuild = false
        burnInExportProgress = 0
        burnInExportStatus = burnInExportQueue.isEmpty ? "Preparing export..." : "Preparing export... \(burnInExportQueue.count) queued"
        burnInExportFilename = job.destination.lastPathComponent
        burnInCurrentExport = queueItem(for: job)
        refreshBurnInExportQueueState()
        outputURL = nil
        reportURL = nil
        burnInLastExportSummary = ""

        burnInExportTask = Task.detached(priority: .userInitiated) { [self, job] in
            do {
                let stats: BurnInExportStats
                switch job.kind {
                case .burnedInVideo(let source):
                    stats = try await Self.renderBurnInVideo(
                        source: source,
                        destination: job.destination,
                        snapshot: job.snapshot,
                        progress: { frame, totalFrames, startedAt in
                            await MainActor.run {
                                self.updateBurnInExportProgress(frame: frame, totalFrames: totalFrames, startedAt: startedAt)
                            }
                        },
                        status: { message in
                            await MainActor.run {
                                self.burnInExportStatus = message
                            }
                        }
                    )
                case .transparentOverlay:
                    stats = try await Self.renderTransparentBurnInOverlay(
                        destination: job.destination,
                        snapshot: job.snapshot,
                        progress: { frame, totalFrames, startedAt in
                            await MainActor.run {
                                self.updateBurnInExportProgress(frame: frame, totalFrames: totalFrames, startedAt: startedAt)
                            }
                        },
                        status: { message in
                            await MainActor.run {
                                self.burnInExportStatus = message
                            }
                        }
                    )
                }
                guard !Task.isCancelled else { throw CancellationError() }
                await MainActor.run {
                    self.outputURL = job.destination
                    self.state = .succeeded
                    self.burnInLastExportSummary = self.formatBurnInExportStats(stats)
                    _ = self.appendBurnInExportBenchmark(destination: job.destination, stats: stats, snapshot: job.snapshot)
                    self.log = [
                        "Data Burn-In video exported: \(job.destination.lastPathComponent)",
                        self.burnInLastExportSummary,
                        "Export benchmark recorded internally.",
                    ].joined(separator: "\n")
                    self.burnInExportProgress = nil
                    self.burnInExportStatus = ""
                    self.burnInExportFilename = ""
                    self.burnInCurrentExport = nil
                    self.burnInExportTask = nil
                    self.refreshBurnInExportQueueState()
                    if self.burnInRevealExportWhenDone {
                        NSWorkspace.shared.open(job.destination)
                    }
                    self.startNextBurnInExportIfNeeded()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.state = .idle
                    self.log = "Data Burn-In export cancelled."
                    self.burnInExportProgress = nil
                    self.burnInExportStatus = ""
                    self.burnInExportFilename = ""
                    self.burnInCurrentExport = nil
                    self.burnInExportTask = nil
                    self.refreshBurnInExportQueueState()
                    self.startNextBurnInExportIfNeeded()
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    self.log = message
                    self.burnInExportProgress = nil
                    self.burnInExportStatus = ""
                    self.burnInExportFilename = ""
                    self.burnInCurrentExport = nil
                    self.burnInExportTask = nil
                    self.refreshBurnInExportQueueState()
                    self.showAlert(title: "Export failed", message: message)
                    self.startNextBurnInExportIfNeeded()
                }
            }
        }
    }

    func cancelBurnInExport() {
        burnInExportTask?.cancel()
        burnInExportStatus = "Cancelling..."
    }

    func cancelAllBurnInExports() {
        burnInExportQueue.removeAll()
        refreshBurnInExportQueueState()
        cancelBurnInExport()
    }

    func removeQueuedBurnInExport(id: UUID) {
        burnInExportQueue.removeAll { $0.id == id }
        refreshBurnInExportQueueState()
    }

    func clearQueuedBurnInExports() {
        burnInExportQueue.removeAll()
        refreshBurnInExportQueueState()
    }

    var burnInQueueSummary: String {
        guard !burnInQueuedExports.isEmpty else { return "" }
        let shown = burnInQueuedExports.prefix(2).map(\.filename).joined(separator: " -> ")
        let remaining = burnInQueuedExports.count - min(2, burnInQueuedExports.count)
        return remaining > 0 ? "\(shown) + \(remaining) more" : shown
    }

    private func refreshBurnInExportQueueState() {
        burnInExportQueueCount = burnInExportQueue.count
        burnInQueuedExports = burnInExportQueue.map(queueItem(for:))
    }

    private func queueItem(for job: BurnInExportJob) -> BurnInExportQueueItem {
        BurnInExportQueueItem(
            id: job.id,
            filename: job.destination.lastPathComponent,
            mode: job.snapshot.exportMode.rawValue,
            codec: "\(job.snapshot.exportCodec.rawValue) / \(job.snapshot.exportContainer.rawValue)",
            destinationPath: job.destination.path
        )
    }

    private func updateBurnInExportProgress(frame: Int, totalFrames: Int, startedAt: Date) {
        guard totalFrames > 0 else { return }
        let completed = min(max(frame, 0), totalFrames)
        let progress = Double(completed) / Double(totalFrames)
        burnInExportProgress = progress
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = progress > 0 ? max(0, elapsed * ((1 - progress) / progress)) : 0
        let queueSuffix = burnInExportQueueCount > 0 ? " - \(burnInExportQueueCount) queued" : ""
        burnInExportStatus = "Exporting \(Int(progress * 100))% - \(formatDuration(remaining)) remaining\(queueSuffix)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 1 else { return "less than 1s" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private func formatBurnInExportStats(_ stats: BurnInExportStats) -> String {
        let fps = stats.renderFPS.isFinite ? stats.renderFPS : 0
        let realtime = stats.realtimeMultiple.isFinite ? stats.realtimeMultiple : 0
        return "Export time \(formatDuration(stats.elapsedSeconds)); rendered \(stats.frameCount) frames at \(String(format: "%.1f", fps)) fps (\(String(format: "%.2f", realtime))x realtime)."
    }

    private func appendBurnInExportBenchmark(destination: URL, stats: BurnInExportStats, snapshot: BurnInRenderSnapshot) -> URL {
        let url = CacheManager.supportURL.appendingPathComponent("ExportBenchmarks.tsv")
        let header = [
            "date",
            "file",
            "mode",
            "codec",
            "container",
            "bitrate_mbps",
            "customizer_visible",
            "duration_seconds",
            "frames",
            "elapsed_seconds",
            "render_fps",
            "realtime_multiple",
            "output_bytes",
        ].joined(separator: "\t") + "\n"
        let line = [
            ISO8601DateFormatter().string(from: Date()),
            destination.path,
            snapshot.exportMode.rawValue,
            snapshot.exportCodec.rawValue,
            snapshot.exportContainer.rawValue,
            String(format: "%.0f", snapshot.exportBitrateMbps),
            snapshot.customizerVisible ? "yes" : "no",
            String(format: "%.3f", stats.timelineDurationSeconds),
            "\(stats.frameCount)",
            String(format: "%.3f", stats.elapsedSeconds),
            String(format: "%.3f", stats.renderFPS),
            String(format: "%.3f", stats.realtimeMultiple),
            "\(stats.outputBytes)",
        ].joined(separator: "\t") + "\n"
        do {
            try FileManager.default.createDirectory(at: CacheManager.supportURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try header.write(to: url, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            log = "Could not save export benchmark: \(error.localizedDescription)"
        }
        return url
    }

    nonisolated private static func renderBurnInVideo(
        source: URL,
        destination: URL,
        snapshot: BurnInRenderSnapshot,
        progress: @escaping @Sendable (Int, Int, Date) async -> Void,
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> BurnInExportStats {
        let asset = AVURLAsset(url: source)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NodeRunner.ProcessFailure(message: "The selected video has no video track.")
        }
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !sourceAudioTracks.isEmpty
        let outputFileType = exportFileType(codec: snapshot.exportCodec, container: snapshot.exportContainer)
        let outputFileExtension = exportFileExtension(codec: snapshot.exportCodec, container: snapshot.exportContainer)
        let writesAudioInline = shouldWriteBurnInAudioInline(codec: snapshot.exportCodec, hasAudio: hasAudio)
        let duration = try await asset.load(.duration)
        let renderSize = try await Self.renderSize(for: sourceVideoTrack)
        let width = max(16, Int(renderSize.width.rounded()))
        let height = max(16, Int(renderSize.height.rounded()))
        let frameDuration = max(snapshot.frameDurationSeconds, 1.0 / 24.0)
        let assetDurationSeconds = duration.seconds.isFinite ? duration.seconds : snapshot.durationSeconds
        let exportStartSeconds = min(max(snapshot.exportStartSeconds, 0), max(assetDurationSeconds - frameDuration, 0))
        let durationSeconds = max(min(snapshot.durationSeconds, max(assetDurationSeconds - exportStartSeconds, frameDuration)), frameDuration)
        let estimatedFrames = max(1, Int((durationSeconds / frameDuration).rounded(.up)))
        let estimatedBytes = estimatedBurnInExportBytes(
            width: width,
            height: height,
            frameDuration: frameDuration,
            durationSeconds: durationSeconds,
            codec: snapshot.exportCodec,
            bitrateMbps: snapshot.exportBitrateMbps,
            needsAudioMux: hasAudio && !writesAudioInline,
            isTransparentOverlay: false
        )
        try prepareDestinationForExport(estimatedBytes: estimatedBytes, destination: destination, needsAudioMux: hasAudio && !writesAudioInline)
        cleanupStaleBurnInExportTemps(in: destination.deletingLastPathComponent())
        let videoOnlyDestination = temporaryExportURL(
            for: destination,
            fileExtension: writesAudioInline || !hasAudio ? outputFileExtension : "mov"
        )
        defer { try? FileManager.default.removeItem(at: videoOnlyDestination) }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NodeRunner.ProcessFailure(message: "Could not create video reader.")
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: exportStartSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceVideoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw NodeRunner.ProcessFailure(message: "Could not read video frames.")
        }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: videoOnlyDestination)
        let writer = try AVAssetWriter(
            outputURL: videoOnlyDestination,
            fileType: writesAudioInline || !hasAudio ? outputFileType : .mov
        )
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoWriterSettings(width: width, height: height, snapshot: snapshot)
        )
        input.expectsMediaDataInRealTime = false
        input.performsMultiPassEncodingIfSupported = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else {
            throw NodeRunner.ProcessFailure(message: "Could not create video writer.")
        }
        writer.add(input)

        var audioReader: AVAssetReader?
        var audioPipes: [BurnInAudioPipe] = []
        if writesAudioInline {
            let readerForAudio = try AVAssetReader(asset: asset)
            readerForAudio.timeRange = reader.timeRange
            for sourceAudioTrack in sourceAudioTracks {
                let audioOutput = AVAssetReaderTrackOutput(track: sourceAudioTrack, outputSettings: audioReaderSettings())
                audioOutput.alwaysCopiesSampleData = false
                guard readerForAudio.canAdd(audioOutput) else { continue }

                let audioSettings = try await audioWriterSettings(
                    for: sourceAudioTrack,
                    outputFileType: outputFileType,
                    preserveChannels: true
                )
                var audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = false
                if !writer.canAdd(audioInput) {
                    let fallbackSettings = try await audioWriterSettings(
                        for: sourceAudioTrack,
                        outputFileType: outputFileType,
                        preserveChannels: false
                    )
                    audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: fallbackSettings)
                    audioInput.expectsMediaDataInRealTime = false
                }
                guard writer.canAdd(audioInput) else {
                    throw NodeRunner.ProcessFailure(message: "Could not create audio writer for the selected export codec.")
                }
                readerForAudio.add(audioOutput)
                writer.add(audioInput)
                audioPipes.append(BurnInAudioPipe(output: audioOutput, input: audioInput))
            }
            if !audioPipes.isEmpty {
                audioReader = readerForAudio
            }
        }
        guard reader.startReading() else {
            throw reader.error ?? NodeRunner.ProcessFailure(message: "Could not start video reader.")
        }
        if let audioReader {
            guard audioReader.startReading() else {
                throw audioReader.error ?? NodeRunner.ProcessFailure(message: "Could not start audio reader.")
            }
        }
        guard writer.startWriting() else {
            throw writer.error ?? NodeRunner.ProcessFailure(message: "Could not start video export.")
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if Task.isCancelled {
                reader.cancelReading()
                audioReader?.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: videoOnlyDestination)
            }
        }

        let startedAt = Date()
        let ciContext = makeBurnInCIContext()
        var textCache: [String: BurnInTextLayout] = [:]
        let sourceStartTime = CMTime(seconds: exportStartSeconds, preferredTimescale: 600)
        var frame = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
                  let pool = adaptor.pixelBufferPool else {
                throw NodeRunner.ProcessFailure(message: "Could not read a video frame.")
            }
            var outputBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
            guard let outputBuffer else {
                throw NodeRunner.ProcessFailure(message: "Could not create export frame.")
            }
            renderSourceFrame(sourceBuffer, to: outputBuffer, context: ciContext)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = presentationTime.seconds.isFinite ? presentationTime.seconds : (Double(frame) * frameDuration)
            let renderPosition = min(max(seconds, 0), snapshot.manifest.timeline.durationSeconds)
            drawBurnInOverlayFrame(
                buffer: outputBuffer,
                renderSize: renderSize,
                positionSeconds: renderPosition,
                textCache: &textCache,
                snapshot: snapshot
            )
            let outputTime = CMTimeSubtract(presentationTime, CMTime(seconds: exportStartSeconds, preferredTimescale: 600))
            if !adaptor.append(outputBuffer, withPresentationTime: outputTime) {
                throw writer.error ?? NodeRunner.ProcessFailure(message: "Could not write export frame.")
            }
            if !audioPipes.isEmpty {
                _ = try drainBurnInAudioPipes(audioPipes, sourceStart: sourceStartTime, upTo: outputTime)
            }
            frame += 1
            if frame == 1 || frame % 60 == 0 {
                await progress(min(frame, estimatedFrames), estimatedFrames, startedAt)
                await Task.yield()
            }
        }
        input.markAsFinished()
        var audioDrainIdleStartedAt = Date()
        while audioPipes.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            let didDrain = try drainBurnInAudioPipes(audioPipes, sourceStart: sourceStartTime, upTo: nil)
            if !didDrain {
                if Date().timeIntervalSince(audioDrainIdleStartedAt) > 20 {
                    throw writer.error ?? audioReader?.error ?? reader.error ?? NodeRunner.ProcessFailure(
                        message: "Audio export stalled while finalizing. Video reader: \(reader.status.rawValue), audio reader: \(audioReader?.status.rawValue ?? -1), writer: \(writer.status.rawValue)."
                    )
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            } else {
                audioDrainIdleStartedAt = Date()
            }
        }
        try Task.checkCancellation()
        await status("Finalizing rendered video...")
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NodeRunner.ProcessFailure(message: "Video export failed while reading frames.")
        }
        if audioReader?.status == .failed {
            throw audioReader?.error ?? NodeRunner.ProcessFailure(message: "Audio export failed while reading samples.")
        }
        if writer.status != .completed {
            throw writer.error ?? NodeRunner.ProcessFailure(message: "Video export failed.")
        }
        await progress(estimatedFrames, estimatedFrames, startedAt)
        if hasAudio && !writesAudioInline {
            await progress(estimatedFrames, estimatedFrames, startedAt)
            await status("Adding original audio...")
            try Task.checkCancellation()
            try await muxOriginalAudio(
                videoOnly: videoOnlyDestination,
                audioSource: source,
                destination: destination,
                snapshot: snapshot,
                sourceStartSeconds: exportStartSeconds,
                durationSeconds: durationSeconds
            )
        } else {
            await status("Moving export into place...")
            try replaceExportTempFile(videoOnlyDestination, destination: destination)
        }
        return BurnInExportStats(
            frameCount: frame,
            timelineDurationSeconds: durationSeconds,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            outputBytes: fileSize(at: destination)
        )
    }

    nonisolated private static func shouldWriteBurnInAudioInline(codec: BurnInExportCodec, hasAudio: Bool) -> Bool {
        hasAudio
    }

    nonisolated private static func effectiveBurnInExportContainer(
        codec: BurnInExportCodec,
        requested: BurnInExportContainer
    ) -> BurnInExportContainer {
        codec.usesBitrate ? requested : .mov
    }

    nonisolated private static func exportFileExtension(
        codec: BurnInExportCodec,
        container: BurnInExportContainer
    ) -> String {
        effectiveBurnInExportContainer(codec: codec, requested: container).fileExtension
    }

    nonisolated private static func exportFileType(
        codec: BurnInExportCodec,
        container: BurnInExportContainer
    ) -> AVFileType {
        effectiveBurnInExportContainer(codec: codec, requested: container).outputFileType
    }

    nonisolated private static func audioReaderSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    nonisolated private static func audioWriterSettings(
        for track: AVAssetTrack,
        outputFileType: AVFileType,
        preserveChannels: Bool
    ) async throws -> [String: Any] {
        let format = try await audioFormatInfo(for: track)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48_000
        let sourceChannels = max(1, format.channelCount)
        let channelCount = preserveChannels ? sourceChannels : min(sourceChannels, 2)

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: max(96_000, min(640_000, channelCount * 128_000)),
        ]
    }

    nonisolated private static func audioFormatInfo(for track: AVAssetTrack) async throws -> (sampleRate: Double, channelCount: Int) {
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
            let sampleRate = streamDescription.pointee.mSampleRate
            let channels = Int(streamDescription.pointee.mChannelsPerFrame)
            return (sampleRate, channels)
        }
        return (48_000, 2)
    }

    @discardableResult
    nonisolated private static func drainBurnInAudioPipes(
        _ pipes: [BurnInAudioPipe],
        sourceStart: CMTime,
        upTo outputLimit: CMTime?
    ) throws -> Bool {
        var didDrain = false
        for pipe in pipes where !pipe.finished {
            while pipe.input.isReadyForMoreMediaData {
                let sample: CMSampleBuffer
                if let pendingSample = pipe.pendingSample {
                    sample = pendingSample
                } else if let nextSample = pipe.output.copyNextSampleBuffer() {
                    sample = nextSample
                } else {
                    pipe.input.markAsFinished()
                    pipe.finished = true
                    didDrain = true
                    break
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let outputTime = CMTimeSubtract(presentationTime, sourceStart)
                if let outputLimit, CMTimeCompare(outputTime, outputLimit) > 0 {
                    pipe.pendingSample = sample
                    break
                }
                pipe.pendingSample = nil
                guard CMTimeCompare(outputTime, .zero) >= 0 else {
                    didDrain = true
                    continue
                }
                let shiftedSample = try shiftedBurnInAudioSample(sample, by: sourceStart)
                guard pipe.input.append(shiftedSample) else {
                    throw NodeRunner.ProcessFailure(message: "Could not write audio into the export.")
                }
                didDrain = true
            }
        }
        return didDrain
    }

    nonisolated private static func shiftedBurnInAudioSample(_ sample: CMSampleBuffer, by sourceStart: CMTime) throws -> CMSampleBuffer {
        var timingCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard status == noErr, timingCount > 0 else {
            throw NodeRunner.ProcessFailure(message: "Could not read audio timing for export.")
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: timingCount
        )
        status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: timingCount,
            arrayToFill: &timing,
            entriesNeededOut: nil
        )
        guard status == noErr else {
            throw NodeRunner.ProcessFailure(message: "Could not prepare audio timing for export.")
        }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, sourceStart)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, sourceStart)
            }
        }

        var shiftedSample: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &shiftedSample
        )
        guard status == noErr, let shiftedSample else {
            throw NodeRunner.ProcessFailure(message: "Could not shift audio timing for export.")
        }
        return shiftedSample
    }

    nonisolated private static func muxOriginalAudio(
        videoOnly: URL,
        audioSource: URL,
        destination: URL,
        snapshot: BurnInRenderSnapshot,
        sourceStartSeconds: Double,
        durationSeconds: Double
    ) async throws {
        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioSource)
        let composition = AVMutableComposition()
        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NodeRunner.ProcessFailure(message: "Could not prepare rendered video for audio mux.")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideoTrack, at: .zero)
        let sourceStart = CMTime(seconds: max(0, sourceStartSeconds), preferredTimescale: 600)
        for sourceAudioTrack in try await audioAsset.loadTracks(withMediaType: .audio) {
            guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let sourceTimeRange = try await sourceAudioTrack.load(.timeRange)
            let audioStart = CMTimeAdd(sourceTimeRange.start, sourceStart)
            let sourceEnd = CMTimeAdd(sourceTimeRange.start, sourceTimeRange.duration)
            guard CMTimeCompare(audioStart, sourceEnd) < 0 else { continue }
            let availableDuration = CMTimeSubtract(sourceEnd, audioStart)
            let muxDuration = minTime(videoDuration, availableDuration)
            guard CMTimeCompare(muxDuration, .zero) > 0 else { continue }
            try audioTrack.insertTimeRange(CMTimeRange(start: audioStart, duration: muxDuration), of: sourceAudioTrack, at: .zero)
        }
        let tempDestination = temporaryExportURL(for: destination, fileExtension: snapshot.exportCodec.fileExtension)
        defer { try? FileManager.default.removeItem(at: tempDestination) }
        try? FileManager.default.removeItem(at: tempDestination)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NodeRunner.ProcessFailure(message: "Could not create audio pass-through exporter.")
        }
        try await exporter.export(to: tempDestination, as: snapshot.exportCodec.outputFileType)
        try replaceExportTempFile(tempDestination, destination: destination)
    }

    nonisolated private static func renderTransparentBurnInOverlay(
        destination: URL,
        snapshot: BurnInRenderSnapshot,
        progress: @escaping @Sendable (Int, Int, Date) async -> Void,
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> BurnInExportStats {
        let manifest = snapshot.manifest
        let width = max(16, manifest.timeline.width ?? 1920)
        let height = max(16, manifest.timeline.height ?? 1080)
        let renderSize = CGSize(width: width, height: height)
        let frameDuration = max(snapshot.frameDurationSeconds, 1.0 / 24.0)
        let durationSeconds = max(snapshot.durationSeconds, frameDuration)
        let frameCount = max(1, Int((durationSeconds / frameDuration).rounded(.up)))
        let frameTimescale = CMTimeScale(max(1, Int((1.0 / frameDuration).rounded())))
        let estimatedBytes = estimatedBurnInExportBytes(
            width: width,
            height: height,
            frameDuration: frameDuration,
            durationSeconds: durationSeconds,
            codec: .proRes4444,
            bitrateMbps: snapshot.exportBitrateMbps,
            needsAudioMux: false,
            isTransparentOverlay: true
        )
        try prepareDestinationForExport(estimatedBytes: estimatedBytes, destination: destination, needsAudioMux: false)
        cleanupStaleBurnInExportTemps(in: destination.deletingLastPathComponent())
        let tempDestination = temporaryExportURL(for: destination, fileExtension: "mov")
        defer { try? FileManager.default.removeItem(at: tempDestination) }

        try? FileManager.default.removeItem(at: tempDestination)
        let writer = try AVAssetWriter(outputURL: tempDestination, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        input.performsMultiPassEncodingIfSupported = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else {
            throw NodeRunner.ProcessFailure(message: "Could not create transparent overlay writer.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NodeRunner.ProcessFailure(message: "Could not start transparent overlay export.")
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if Task.isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: tempDestination)
            }
        }

        let startedAt = Date()
        var textCache: [String: BurnInTextLayout] = [:]

        for frame in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw NodeRunner.ProcessFailure(message: "Could not create transparent overlay pixel buffer pool.")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else {
                throw NodeRunner.ProcessFailure(message: "Could not create transparent overlay frame.")
            }
            let seconds = min(snapshot.exportStartSeconds + Double(frame) * frameDuration, snapshot.exportStartSeconds + durationSeconds)
            drawTransparentBurnInFrame(
                buffer: buffer,
                renderSize: renderSize,
                positionSeconds: seconds,
                textCache: &textCache,
                snapshot: snapshot
            )
            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: frameTimescale)
            if !adaptor.append(buffer, withPresentationTime: presentationTime) {
                throw writer.error ?? NodeRunner.ProcessFailure(message: "Could not write transparent overlay frame.")
            }
            if frame == 0 || frame % 60 == 0 {
                await progress(frame + 1, frameCount, startedAt)
                await Task.yield()
            }
        }

        input.markAsFinished()
        try Task.checkCancellation()
        await status("Finalizing transparent ProRes 4444 overlay...")
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? NodeRunner.ProcessFailure(message: "Transparent overlay export failed.")
        }
        try replaceExportTempFile(tempDestination, destination: destination)
        await progress(frameCount, frameCount, startedAt)
        return BurnInExportStats(
            frameCount: frameCount,
            timelineDurationSeconds: durationSeconds,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            outputBytes: fileSize(at: destination)
        )
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    nonisolated private static func temporaryExportURL(for destination: URL, fileExtension overrideExtension: String? = nil) -> URL {
        let directory = destination.deletingLastPathComponent()
        let basename = destination.deletingPathExtension().lastPathComponent
        let ext = overrideExtension ?? destination.pathExtension
        let filename = ".\(basename)-\(UUID().uuidString)-TurnoverExportTemp" + (ext.isEmpty ? "" : ".\(ext)")
        return directory.appendingPathComponent(filename)
    }

    nonisolated private static func cleanupStaleBurnInExportTemps(in directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for item in items where item.lastPathComponent.contains("-TurnoverExportTemp") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    nonisolated private static func replaceExportTempFile(_ tempURL: URL, destination: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: tempURL, to: destination)
        } catch {
            try? manager.removeItem(at: tempURL)
            throw error
        }
    }

    nonisolated private static func prepareDestinationForExport(estimatedBytes: Int64, destination: URL, needsAudioMux: Bool) throws {
        try ensureEnoughSpace(for: estimatedBytes, destination: destination, needsAudioMux: needsAudioMux)
    }

    nonisolated private static func ensureEnoughSpace(for estimatedBytes: Int64, destination: URL, needsAudioMux: Bool) throws {
        guard estimatedBytes > 0 else { return }
        let space = exportSpaceStatus(estimatedBytes: estimatedBytes, destination: destination, needsAudioMux: needsAudioMux)
        guard space.hasEnoughSpace else {
            throw NodeRunner.ProcessFailure(
                message: "Not enough disk space for this export. Estimated need \(formatBytes(space.requiredBytes)); available \(formatBytes(space.availableBytes)). Free space or choose a different destination."
            )
        }
    }

    nonisolated private static func exportSpaceStatus(
        estimatedBytes: Int64,
        destination: URL,
        needsAudioMux: Bool
    ) -> (hasEnoughSpace: Bool, availableBytes: Int64, requiredBytes: Int64) {
        guard estimatedBytes > 0 else { return (true, 0, 0) }
        let directory = destination.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return (true, 0, estimatedBytes)
        }
        let replaceableBytes = FileManager.default.fileExists(atPath: destination.path) ? fileSize(at: destination) : 0
        let availableBytes = Int64(available) + replaceableBytes
        let requiredBytes = exportRequiredBytes(forEstimatedBytes: estimatedBytes, needsAudioMux: needsAudioMux)
        return (availableBytes >= requiredBytes, availableBytes, requiredBytes)
    }

    nonisolated private static func exportRequiredBytes(forEstimatedBytes estimatedBytes: Int64, needsAudioMux: Bool) -> Int64 {
        estimatedBytes * (needsAudioMux ? 2 : 1) + 2_000_000_000
    }

    nonisolated private static func estimatedBurnInExportBytes(
        width: Int,
        height: Int,
        frameDuration: Double,
        durationSeconds: Double,
        codec: BurnInExportCodec,
        bitrateMbps: Double,
        needsAudioMux: Bool,
        isTransparentOverlay: Bool
    ) -> Int64 {
        let fps = max(1, 1.0 / max(frameDuration, 1.0 / 120.0))
        let scale = (Double(width) * Double(height) * fps) / (1920.0 * 1080.0 * 24.0)
        let baseMbps: Double
        switch codec {
        case .proRes422Proxy: baseMbps = 45
        case .proRes422LT: baseMbps = 102
        case .proRes422: baseMbps = 147
        case .proRes422HQ: baseMbps = 220
        case .proRes4444: baseMbps = isTransparentOverlay ? 22 : 220
        case .h264, .hevc: baseMbps = max(1, bitrateMbps)
        }
        let estimated = (baseMbps * scale * durationSeconds / 8.0) * 1_000_000.0
        return Int64(estimated * 1.15)
    }

    nonisolated private static func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(String(format: "%.1f", value)) \(units[unit])"
    }

    nonisolated private static func makeBurnInCIContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    nonisolated private static func videoWriterSettings(width: Int, height: Int, snapshot: BurnInRenderSnapshot) -> [String: Any] {
        let codec: AVVideoCodecType = switch snapshot.exportCodec {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes4444: .proRes4444
        case .proRes422HQ: .proRes422HQ
        case .proRes422LT: .proRes422LT
        case .proRes422Proxy: .proRes422Proxy
        case .proRes422: .proRes422
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if snapshot.exportCodec.usesBitrate {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(snapshot.exportBitrateMbps * 1_000_000),
            ]
        }
        return settings
    }

    nonisolated private static func copyPixelBuffer(_ source: CVPixelBuffer, to destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        for row in 0..<rows {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                rowBytes
            )
        }
    }

    nonisolated private static func renderSourceFrame(_ source: CVPixelBuffer, to destination: CVPixelBuffer, context: CIContext) {
        let image = CIImage(cvPixelBuffer: source)
        context.render(image, to: destination)
    }

    nonisolated private static func drawTransparentBurnInFrame(
        buffer: CVPixelBuffer,
        renderSize: CGSize,
        positionSeconds: Double,
        textCache: inout [String: BurnInTextLayout],
        snapshot: BurnInRenderSnapshot
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(baseAddress, 0, bytesPerRow * height)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        drawBurnInOverlayFrame(
            context: context,
            renderSize: renderSize,
            positionSeconds: positionSeconds,
            textCache: &textCache,
            snapshot: snapshot
        )
    }

    nonisolated private static func drawBurnInOverlayFrame(
        buffer: CVPixelBuffer,
        renderSize: CGSize,
        positionSeconds: Double,
        textCache: inout [String: BurnInTextLayout],
        snapshot: BurnInRenderSnapshot
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        drawBurnInOverlayFrame(
            context: context,
            renderSize: renderSize,
            positionSeconds: positionSeconds,
            textCache: &textCache,
            snapshot: snapshot
        )
    }

    nonisolated private static func drawBurnInOverlayFrame(
        context: CGContext,
        renderSize: CGSize,
        positionSeconds: Double,
        textCache: inout [String: BurnInTextLayout],
        snapshot: BurnInRenderSnapshot
    ) {
        context.saveGState()
        for field in snapshot.fields where field.enabled {
            let text = burnInPreviewText(for: field, at: positionSeconds, snapshot: snapshot).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            drawBurnInText(text, field: field, renderSize: renderSize, textCache: &textCache, snapshot: snapshot, context: context)
        }
        context.restoreGState()
    }

    nonisolated private static func drawBurnInText(
        _ text: String,
        field: BurnInField,
        renderSize: CGSize,
        textCache: inout [String: BurnInTextLayout],
        snapshot: BurnInRenderSnapshot,
        context: CGContext
    ) {
        let style = effectiveBurnInStyle(for: field, snapshot: snapshot)
        let fontSize = CGFloat(style.fontSize)
        let horizontalPadding = CGFloat(style.horizontalPadding)
        let verticalPadding = CGFloat(style.verticalPadding)
        let textInsetX = burnInTextInsetX
        let textInsetY = burnInTextInsetY
        let maxWidth = max(80, renderSize.width - (horizontalPadding * 2))
        let cacheKey = [
            text,
            field.anchor.rawValue,
            String(format: "%.2f", fontSize),
            style.textColor.rawValue,
            style.textColorValue.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.red, $0.green, $0.blue, $0.alpha) } ?? "",
            String(format: "%.2f", style.textOpacity),
            String(format: "%.1f", maxWidth),
        ].joined(separator: "\u{1F}")
        let layout: BurnInTextLayout
        if let cached = textCache[cacheKey] {
            layout = cached
        } else {
            let paragraph = coreTextParagraphStyle(field.anchor)
            let font = CTFontCreateWithName("Menlo-Semibold" as CFString, fontSize, nil)
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: cgColor(style),
                kCTParagraphStyleAttributeName: paragraph,
            ]
            let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)!
            if !text.contains("\n") {
                let line = CTLineCreateWithAttributedString(attributed)
                let measuredWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                layout = BurnInTextLayout(
                    attributed: attributed,
                    framesetter: nil,
                    line: line,
                    size: CGSize(
                        width: min(maxWidth, max(120, ceil(measuredWidth) + (textInsetX * 2))),
                        height: fontSize * 1.35 + (textInsetY * 2)
                    ),
                    textLength: CFAttributedStringGetLength(attributed)
                )
            } else {
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRange(location: 0, length: 0),
                    nil,
                    CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                    nil
                )
                layout = BurnInTextLayout(
                    attributed: attributed,
                    framesetter: framesetter,
                    line: nil,
                    size: CGSize(
                        width: min(maxWidth, max(120, ceil(measured.width) + (textInsetX * 2))),
                        height: max(fontSize * 1.35 + (textInsetY * 2), ceil(measured.height) + (textInsetY * 2))
                    ),
                    textLength: CFAttributedStringGetLength(attributed)
                )
            }
            if textCache.count < 2000 {
                textCache[cacheKey] = layout
            }
        }
        let frame = CGRect(
            origin: burnInLayerOrigin(
                anchor: field.anchor,
                size: layout.size,
                renderSize: renderSize,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            ),
            size: layout.size
        )
        context.setFillColor(CGColor(gray: 0, alpha: CGFloat(style.backgroundOpacity)))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: burnInTextCornerRadius, cornerHeight: burnInTextCornerRadius, transform: nil))
        context.fillPath()
        drawCoreText(layout: layout, in: frame.insetBy(dx: textInsetX, dy: textInsetY), context: context)
    }

    nonisolated private static func renderSize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let natural = naturalSize.applying(preferredTransform)
        return CGSize(width: abs(natural.width), height: abs(natural.height))
    }

    private func burnInTextLayer(for field: BurnInField, text: String, renderSize: CGSize, duration: CMTime) -> CATextLayer {
        let style = effectiveBurnInStyle(for: field)
        let layer = CATextLayer()
        layer.string = text
        layer.font = "Menlo" as CFTypeRef
        layer.fontSize = CGFloat(style.fontSize)
        layer.foregroundColor = Self.cgColor(style)
        layer.backgroundColor = NSColor.black.withAlphaComponent(style.backgroundOpacity).cgColor
        layer.contentsScale = 2
        layer.isWrapped = true
        layer.alignmentMode = textAlignmentMode(field.anchor)

        let lineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let maxWidth = max(80, renderSize.width - CGFloat(style.horizontalPadding * 2))
        let textHeight = CGFloat(lineCount) * CGFloat(style.fontSize) * 1.35 + (Self.burnInTextInsetY * 2)
        let textWidth = min(maxWidth, max(120, CGFloat(text.count) * CGFloat(style.fontSize) * 0.62 + (Self.burnInTextInsetX * 2)))
        layer.frame = CGRect(
            origin: Self.burnInLayerOrigin(
                anchor: field.anchor,
                size: CGSize(width: textWidth, height: textHeight),
                renderSize: renderSize,
                horizontalPadding: CGFloat(style.horizontalPadding),
                verticalPadding: CGFloat(style.verticalPadding)
            ),
            size: CGSize(width: textWidth, height: textHeight)
        )
        layer.cornerRadius = Self.burnInTextCornerRadius
        addDynamicTextAnimation(to: layer, field: field, duration: duration)
        return layer
    }

    private func addDynamicTextAnimation(to layer: CATextLayer, field: BurnInField, duration: CMTime) {
        let durationSeconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0)
        guard durationSeconds > 0 else { return }
        let step = max(burnInFrameDurationSeconds, 1.0 / 24.0)
        let maxSamples = 30000
        let sampleCount = min(max(2, Int((durationSeconds / step).rounded(.up)) + 1), maxSamples)
        let originalPosition = burnInPositionSeconds
        var values: [String] = []
        var keyTimes: [NSNumber] = []
        for index in 0..<sampleCount {
            let seconds = min(Double(index) * step, durationSeconds)
            burnInPositionSeconds = seconds
            values.append(burnInPreviewText(for: field))
            keyTimes.append(NSNumber(value: durationSeconds > 0 ? seconds / durationSeconds : 0))
        }
        burnInPositionSeconds = originalPosition
        guard Set(values).count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "string")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = durationSeconds
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "dynamicBurnInText")
    }

    nonisolated private static func burnInLayerOrigin(
        anchor: BurnInAnchor,
        size: CGSize,
        renderSize: CGSize,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) -> CGPoint {
        let x: CGFloat
        switch anchor {
        case .topLeft, .middleLeft, .bottomLeft:
            x = horizontalPadding
        case .topCenter, .middleCenter, .bottomCenter:
            x = (renderSize.width - size.width) / 2
        case .topRight, .middleRight, .bottomRight:
            x = renderSize.width - horizontalPadding - size.width
        }

        let y: CGFloat
        switch anchor {
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = verticalPadding
        case .middleLeft, .middleCenter, .middleRight:
            y = (renderSize.height - size.height) / 2
        case .topLeft, .topCenter, .topRight:
            y = renderSize.height - verticalPadding - size.height
        }
        return CGPoint(x: max(0, x), y: max(0, y))
    }

    private func textAlignmentMode(_ anchor: BurnInAnchor) -> CATextLayerAlignmentMode {
        switch anchor {
        case .topLeft, .middleLeft, .bottomLeft: .left
        case .topCenter, .middleCenter, .bottomCenter: .center
        case .topRight, .middleRight, .bottomRight: .right
        }
    }

    private func nsTextAlignment(_ anchor: BurnInAnchor) -> NSTextAlignment {
        switch anchor {
        case .topLeft, .middleLeft, .bottomLeft: .left
        case .topCenter, .middleCenter, .bottomCenter: .center
        case .topRight, .middleRight, .bottomRight: .right
        }
    }

    nonisolated private static func coreTextParagraphStyle(_ anchor: BurnInAnchor) -> CTParagraphStyle {
        var alignment: CTTextAlignment = switch anchor {
        case .topLeft, .middleLeft, .bottomLeft: .left
        case .topCenter, .middleCenter, .bottomCenter: .center
        case .topRight, .middleRight, .bottomRight: .right
        }
        return withUnsafePointer(to: &alignment) { pointer in
            var settings = [
                CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer
                ),
            ]
            return CTParagraphStyleCreate(&settings, settings.count)
        }
    }

    nonisolated private static func drawCoreText(layout: BurnInTextLayout, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.textMatrix = .identity
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        if let line = layout.line {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineY = rect.minY + max(0, (rect.height - ascent - descent) / 2) + descent
            context.textPosition = CGPoint(x: rect.minX, y: baselineY)
            CTLineDraw(line, context)
            context.restoreGState()
            return
        }
        guard let framesetter = layout.framesetter else {
            context.restoreGState()
            return
        }
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: layout.textLength),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    nonisolated private static func cgColor(_ style: BurnInStyle) -> CGColor {
        let color = style.textColorValue ?? .preset(style.textColor)
        return CGColor(
            red: max(0, min(1, color.red)),
            green: max(0, min(1, color.green)),
            blue: max(0, min(1, color.blue)),
            alpha: max(0, min(1, color.alpha * style.textOpacity))
        )
    }

    private func nsColor(_ color: BurnInTextColor) -> NSColor {
        switch color {
        case .white: .white
        case .yellow: .systemYellow
        case .cyan: .systemCyan
        case .red: .systemRed
        case .black: .black
        }
    }

    private func currentBurnInSettings() -> SavedBurnInSettings {
        SavedBurnInSettings(
            fields: burnInFields,
            globalStyle: burnInGlobalStyle,
            audioRoleFilter: burnInAudioRoleFilter,
            conditionalText: burnInConditionalText,
            conditions: burnInConditions,
            showLabels: burnInShowLabels,
            showFileExtensions: burnInShowFileExtensions,
            labelOverrides: burnInLabelOverrides,
            analysisDetailOptions: burnInAnalysisDetailOptions,
            exportMode: burnInExportMode,
            exportCodec: burnInExportCodec,
            exportContainer: burnInExportContainer,
            exportBitrateMbps: burnInExportBitrateMbps,
            revealExportWhenDone: burnInRevealExportWhenDone,
            metadataSelections: burnInMetadataSelections,
            sourceLayerLimit: burnInSourceLayerLimit,
            sourceLayerDisplayMode: burnInSourceLayerDisplayMode,
            sourceLayerDetailLayout: burnInSourceLayerDetailLayout,
            sourceLayerDetailOptions: burnInSourceLayerDetailOptions
        )
    }

    func applySelectedBurnInPreset() {
        guard let preset = burnInPresets.first(where: { $0.id == selectedBurnInPresetID }) else { return }
        applyBurnInSettings(preset.settings, saveSelection: false)
    }

    func saveSelectedBurnInPreset() {
        ensureBurnInPresetLibrary()
        guard let index = burnInPresets.firstIndex(where: { $0.id == selectedBurnInPresetID }) else { return }
        burnInPresets[index].settings = currentBurnInSettings()
        saveBurnInPresetLibrary()
    }

    func saveBurnInPresetAs() {
        guard let name = promptForBurnInPresetName(title: "Save Burn-In Preset As", defaultName: nextBurnInPresetName()) else { return }
        let preset = BurnInNamedPreset(id: UUID().uuidString, name: name, settings: currentBurnInSettings())
        burnInPresets.append(preset)
        selectedBurnInPresetID = preset.id
        saveBurnInPresetLibrary()
    }

    func renameSelectedBurnInPreset() {
        guard let index = burnInPresets.firstIndex(where: { $0.id == selectedBurnInPresetID }) else { return }
        guard let name = promptForBurnInPresetName(title: "Rename Burn-In Preset", defaultName: burnInPresets[index].name) else { return }
        burnInPresets[index].name = uniqueBurnInPresetName(name, ignoring: burnInPresets[index].id)
        saveBurnInPresetLibrary()
    }

    func deleteSelectedBurnInPreset() {
        guard burnInPresets.count > 1,
              let index = burnInPresets.firstIndex(where: { $0.id == selectedBurnInPresetID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(burnInPresets[index].name)\"?"
        alert.informativeText = "This removes the local preset from this Mac. Exported JSON files are not touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        burnInPresets.remove(at: index)
        selectedBurnInPresetID = burnInPresets[min(index, burnInPresets.count - 1)].id
        applySelectedBurnInPreset()
        saveBurnInPresetLibrary()
    }

    private func promptForBurnInPresetName(title: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Name this preset for the preset menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func nextBurnInPresetName() -> String {
        uniqueBurnInPresetName("Untitled Preset")
    }

    func exportBurnInPreset() {
        saveSelectedBurnInPreset()
        let panel = NSSavePanel()
        panel.title = "Export Burn-In Preset"
        let presetName = burnInPresets.first(where: { $0.id == selectedBurnInPresetID })?.name ?? "Turnover Burn-In Preset"
        panel.nameFieldStringValue = "\(presetName).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let preset = BurnInNamedPreset(
                id: selectedBurnInPresetID.isEmpty ? UUID().uuidString : selectedBurnInPresetID,
                name: presetName,
                settings: currentBurnInSettings()
            )
            let data = try encoder.encode(preset)
            try data.write(to: url, options: .atomic)
        } catch {
            state = .failed("Could not export Burn-In preset: \(error.localizedDescription)")
        }
    }

    func importBurnInPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import Burn-In Preset"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let imported: BurnInNamedPreset
            if let named = try? decoder.decode(BurnInNamedPreset.self, from: data) {
                imported = BurnInNamedPreset(id: UUID().uuidString, name: uniqueBurnInPresetName(named.name), settings: named.settings)
            } else {
                let settings = try decoder.decode(SavedBurnInSettings.self, from: data)
                imported = BurnInNamedPreset(id: UUID().uuidString, name: uniqueBurnInPresetName(url.deletingPathExtension().lastPathComponent), settings: settings)
            }
            burnInPresets.append(imported)
            selectedBurnInPresetID = imported.id
            applySelectedBurnInPreset()
            saveBurnInPresetLibrary()
        } catch {
            state = .failed("Could not import Burn-In preset: \(error.localizedDescription)")
        }
    }

    private func loadBurnInPresetLibrary() {
        if let data = UserDefaults.standard.data(forKey: burnInPresetLibraryKey),
           let library = try? JSONDecoder().decode(BurnInPresetLibrary.self, from: data),
           !library.presets.isEmpty {
            burnInPresets = library.presets
            selectedBurnInPresetID = library.selectedID.flatMap { id in
                library.presets.contains(where: { $0.id == id }) ? id : nil
            } ?? library.presets[0].id
            applySelectedBurnInPreset()
            return
        }

        if let data = UserDefaults.standard.data(forKey: burnInSettingsKey),
           let settings = try? JSONDecoder().decode(SavedBurnInSettings.self, from: data) {
            let preset = BurnInNamedPreset(id: UUID().uuidString, name: "Custom", settings: settings)
            burnInPresets = [preset]
            selectedBurnInPresetID = preset.id
            applySelectedBurnInPreset()
            saveBurnInPresetLibrary()
            return
        }

        ensureBurnInPresetLibrary()
        applySelectedBurnInPreset()
        saveBurnInPresetLibrary()
    }

    private func ensureBurnInPresetLibrary() {
        if !burnInPresets.isEmpty,
           burnInPresets.contains(where: { $0.id == selectedBurnInPresetID }) {
            return
        }
        let preset = BurnInNamedPreset(id: UUID().uuidString, name: "Custom", settings: currentBurnInSettings())
        burnInPresets = [preset]
        selectedBurnInPresetID = preset.id
    }

    private func saveBurnInPresetLibrary() {
        ensureBurnInPresetLibrary()
        let library = BurnInPresetLibrary(selectedID: selectedBurnInPresetID, presets: burnInPresets)
        if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: burnInPresetLibraryKey)
        }
    }

    private func uniqueBurnInPresetName(_ requested: String, ignoring ignoredID: String? = nil) -> String {
        let base = requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Preset" : requested
        let names = Set(burnInPresets.filter { $0.id != ignoredID }.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func applyBurnInSettings(_ settings: SavedBurnInSettings, saveSelection: Bool = true) {
        burnInGlobalStyle = settings.globalStyle ?? Self.defaultBurnInStyle()
        burnInFields = Self.normalizedBurnInFields(settings.fields)
        burnInAudioRoleFilter = settings.audioRoleFilter
        burnInConditionalText = settings.conditionalText
        burnInConditions = Self.conditions(from: settings)
        burnInShowLabels = settings.showLabels ?? true
        burnInShowFileExtensions = settings.showFileExtensions ?? true
        burnInLabelOverrides = settings.labelOverrides ?? [:]
        burnInAnalysisDetailOptions = settings.analysisDetailOptions ?? Self.defaultBurnInAnalysisDetailOptions()
        burnInExportMode = settings.exportMode ?? .transparentOverlay
        burnInExportCodec = settings.exportCodec ?? .proRes4444
        burnInExportContainer = settings.exportContainer ?? .mp4
        burnInExportBitrateMbps = settings.exportBitrateMbps ?? 20
        burnInRevealExportWhenDone = settings.revealExportWhenDone ?? true
        burnInMetadataSelections = settings.metadataSelections ?? [:]
        burnInSourceLayerLimit = min(max(settings.sourceLayerLimit ?? 1, 0), 6)
        burnInSourceLayerDisplayMode = settings.sourceLayerDisplayMode ?? .compact
        burnInSourceLayerDetailLayout = settings.sourceLayerDetailLayout ?? .oneLine
        burnInSourceLayerDetailOptions = settings.sourceLayerDetailOptions ?? Self.defaultBurnInSourceLayerDetailOptions()
        normalizeBurnInExportSettings()
        if saveSelection { saveSelectedBurnInPreset() }
    }

    func burnInLabelEnabled(for token: String) -> Bool {
        burnInLabelOverrides[token] ?? burnInShowLabels
    }

    func setBurnInLabelEnabled(_ enabled: Bool, for token: String) {
        burnInLabelOverrides[token] = enabled
    }

    func addBurnInCondition() {
        burnInConditions.append(BurnInCondition(subject: .audioRole, contains: "", message: ""))
    }

    func removeBurnInCondition(id: UUID) {
        burnInConditions.removeAll { $0.id == id }
    }

    private static func conditions(from settings: SavedBurnInSettings) -> [BurnInCondition] {
        if let conditions = settings.conditions {
            return conditions
        }
        let filter = settings.audioRoleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = settings.conditionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty, !message.isEmpty else { return [] }
        return [
            BurnInCondition(subject: .audioRole, contains: filter, message: message)
        ]
    }

    private static func normalizedBurnInFields(_ fields: [BurnInField]) -> [BurnInField] {
        var fieldsByAnchor = Dictionary(uniqueKeysWithValues: fields.map { ($0.anchor, $0) })
        return defaultBurnInFields().map { defaultField in
            fieldsByAnchor.removeValue(forKey: defaultField.anchor) ?? defaultField
        }
    }

    private func setBurnInField(_ anchor: BurnInAnchor, template: String, enabled: Bool) {
        guard let index = burnInFields.firstIndex(where: { $0.anchor == anchor }) else { return }
        burnInFields[index].template = template
        burnInFields[index].enabled = enabled
    }

    func accept(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "fcpxml" || ext == "fcpxmld" else {
            state = .failed("Choose a .fcpxml file or .fcpxmld bundle.")
            return
        }
        if ext == "fcpxmld",
           !FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.fcpxml").path) {
            state = .failed("This FCPXML bundle does not contain Info.fcpxml.")
            return
        }
        sourceURL = url
        outputURL = nil
        reportURL = nil
        state = .ready
        log = "Ready to process \(url.lastPathComponent)"
    }

    func acceptForBurnInCustomize(url: URL) {
        accept(url: url)
        guard case .ready = state else { return }
        selectedTool = .dataBurnIn
        runDataBurnIn()
    }

    func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                Task { @MainActor in
                    if let url {
                        self.accept(url: url)
                    } else if let error {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
            return true
        }

        guard let type = finalCutPasteboardTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            Task { @MainActor in
                do {
                    if let error { throw error }
                    guard let data, !data.isEmpty else {
                        throw NodeRunner.ProcessFailure(message: "Final Cut Pro returned an empty FCPXML payload.")
                    }
                    let url = try self.storeFinalCutDrop(data)
                    self.accept(url: url)
                    self.log = "Received \(url.lastPathComponent) directly from Final Cut Pro."
                } catch {
                    self.state = .failed("Could not receive the Final Cut Pro project: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    func runConformPrep() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.conformPrepScript() else {
            state = .failed("The bundled Conform Prep planner is missing.")
            return
        }

        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "Turnover") else {
            log = "Conform Prep cancelled: no output location selected."
            return
        }
        let isBundle = sourceURL.pathExtension.lowercased() == "fcpxmld"
        let plannerSource = isBundle ? sourceURL.appendingPathComponent("Info.fcpxml") : sourceURL
        let report = temporaryReportURL(tool: "conform-prep")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Running Conform Prep..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    if isBundle {
                        let note = "\nstandalone bundle handling:\n- read Info.fcpxml from the source FCPXMLD bundle\n- emitted flat FCPXML; bundle-only sidecars were not copied because flattening can invalidate their clip and timing references\n"
                        let handle = try FileHandle(forWritingTo: report)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(note.utf8))
                        try handle.close()
                    }
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "Conform-Prep", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "Conform Prep completed." : result
                if openInFinalCut {
                    openResultInFinalCut()
                }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runSelectedTool() {
        switch selectedTool {
        case .exportMarkers:
            runExportMarkers()
        case .conformPrep:
            runConformPrep()
        case .autoMarker:
            runAutoMarker()
        case .vfxPullEDL:
            runVFXPullEDL()
        case .vfxNaming:
            runVFXNaming()
        case .vfxTimeline:
            runVFXTimeline()
        case .vfxShotList:
            runVFXShotList()
        case .dataBurnIn:
            runDataBurnIn()
        }
    }

    func runExportMarkers() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.markerExportScript() else {
            state = .failed("The bundled Marker tool is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let outputDirectory = chooseMarkerExportDirectory(suggestedBy: sourceURL) else {
            log = "Marker export cancelled: no output folder selected."
            return
        }
        let markerFilter = markerExportKind.argument
        let markerFormat = markerExportFormat.argument
        let report = temporaryReportURL(tool: "export-markers")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Exporting \(markerExportKind.rawValue.lowercased())..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-dir", outputDirectory.path,
                            "--filter", markerFilter,
                            "--format", markerFormat,
                            "--report", report.path,
                        ]
                    )
                }.value
                let paths = parsePlannerPaths(result)
                guard let markerFile = paths.edl ?? paths.csv ?? paths.txt,
                      FileManager.default.fileExists(atPath: markerFile.path) else {
                    throw NodeRunner.ProcessFailure(message: "Marker export completed without creating a marker export file.")
                }
                outputURL = markerFile
                cacheDebugArtifacts(tool: "Marker", sourceXML: plannerSource, output: markerFile, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = "Marker export completed: \(markerExportFormat.rawValue) marker list created."
                revealOutput()
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runDataBurnIn() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("The bundled Node.js runtime is missing.")
            return
        }
        guard let scriptURL = NodeRunner.dataBurnInIndexScript() else {
            state = .failed("The bundled Data Burn-In preview-cache planner is missing.")
            return
        }
        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        state = .running
        outputURL = nil
        reportURL = nil
        shouldOpenBurnInCustomizerAfterBuild = false
        log = "Building Data Burn-In preview cache..."

        Task {
            do {
                let debugFolder = try createDebugJobDirectory(tool: "Data-Burn-In")
                let destination = debugFolder.appendingPathComponent("VisibleFrameIndex.json")
                let report = debugFolder.appendingPathComponent("Report.txt")
                let result = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-index", destination.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let data = try Data(contentsOf: destination)
                let manifest = try JSONDecoder().decode(VisibleFrameIndex.self, from: data)
                visibleFrameIndex = manifest
                visibleFrameSamplesByFrame = Dictionary(uniqueKeysWithValues: (manifest.frameSamples ?? []).map { ($0.frame, $0) })
                burnInDurationSeconds = max(manifest.timeline.durationSeconds, 0)
                burnInPositionSeconds = 0
                try? FileManager.default.copyItem(at: plannerSource, to: debugFolder.appendingPathComponent("Source.fcpxml"))
                outputURL = nil
                reportURL = report
                try? CacheManager.prepareAndClean()
                refreshCacheSize()
                shouldOpenBurnInCustomizerAfterBuild = true
                state = .succeeded
                log = formatBurnInCacheResult(result)
            } catch {
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    private func formatBurnInCacheResult(_ output: String) -> String {
        let jsonLine = output.split(separator: "\n").last.map(String.init) ?? output
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok" else {
            return "Data Burn-In preview cache completed."
        }
        let segments = object["video_segments"] as? Int ?? 0
        let frames = object["frame_samples"] as? Int ?? 0
        let vfxTitles = object["vfx_titles"] as? Int ?? 0
        let audioRoles = object["audio_roles"] as? Int ?? 0
        return "Data Burn-In preview cache completed: \(segments) video segments, \(frames) frame samples, \(vfxTitles) VFX titles, \(audioRoles) audio roles."
    }

    func runVFXShotList() {
        guard let sourceURL else { return }
        guard let referenceMovieURL else {
            log = "Choose a timeline reference movie before running VFX Shot List."
            return
        }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxShotListManifestScript() else {
            state = .failed("The bundled VFX Shot List manifest planner is missing.")
            return
        }
        guard let excelScriptURL = NodeRunner.vfxShotListExcelScript() else {
            state = .failed("The bundled VFX Shot List Excel generator is missing.")
            return
        }
        guard let exportParent = chooseShotListExportDirectory(suggestedBy: sourceURL) else {
            log = "VFX Shot List cancelled: no output location selected."
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        let jobFolder: URL
        do {
            jobFolder = try createDebugJobDirectory(tool: "VFX-Shot-List")
            try FileManager.default.copyItem(at: plannerSource, to: jobFolder.appendingPathComponent("Source.fcpxml"))
        } catch {
            state = .failed("Could not prepare VFX Shot List: \(error.localizedDescription)")
            return
        }
        let manifest = jobFolder.appendingPathComponent("Manifest.tsv")
        let report = jobFolder.appendingPathComponent("Report.txt")
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Preparing VFX Shot List from user marker anchors..."

        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-manifest", manifest.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let rows = try Self.shotListManifestRows(at: manifest)
                guard let firstRow = rows.first else {
                    throw NodeRunner.ProcessFailure(message: "The VFX Shot List manifest has no marker rows.")
                }
                let projectName = firstRow["project_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resultFolder = uniqueShotListResultFolder(
                    in: exportParent,
                    projectName: projectName?.isEmpty == false ? projectName! : sourceURL.deletingPathExtension().lastPathComponent
                )
                let thumbnailFolder = resultFolder.appendingPathComponent("Thumbnail", isDirectory: true)
                let captureFolder = jobFolder.appendingPathComponent("Captures", isDirectory: true)
                try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)

                let session = try await ReferenceMovieCapture.Session(movieURL: referenceMovieURL)
                log = "Extracting 0/\(rows.count) marker thumbnails from the reference movie..."
                for (index, row) in rows.enumerated() {
                    guard let movieSecondsText = row["movie_seconds"],
                          let movieSeconds = Double(movieSecondsText) else {
                        throw NodeRunner.ProcessFailure(message: "Shot \(index + 1) has no reference movie time.")
                    }
                    let thumbnailName = row["suggested_thumb_name"]?.isEmpty == false
                        ? row["suggested_thumb_name"]!
                        : String(format: "VFX_%03d.jpg", index + 1)
                    _ = try await session.captureFrame(
                        seconds: movieSeconds,
                        outputURL: thumbnailFolder.appendingPathComponent(thumbnailName),
                        thumbnail: true
                    )
                    let completed = index + 1
                    if completed == rows.count || completed == 1 || completed % 10 == 0 {
                        log = "Extracting \(completed)/\(rows.count) marker thumbnails from the reference movie..."
                    }
                }

                log = "Generating the VFX Shot List Excel workbook..."
                let safeProject = sanitizeFilename(projectName?.isEmpty == false ? projectName! : "Project")
                let workbook = resultFolder.appendingPathComponent("VFX Shot List - \(safeProject).xlsx")
                _ = try await Task.detached(priority: .userInitiated) {
                    try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            excelScriptURL.path,
                            "--manifest", manifest.path,
                            "--captures", captureFolder.path,
                            "--thumbs", thumbnailFolder.path,
                            "--output", workbook.path,
                            "--title", "VFX Shot List - \(projectName ?? "Project")",
                        ]
                    )
                }.value
                guard FileManager.default.fileExists(atPath: workbook.path) else {
                    throw NodeRunner.ProcessFailure(message: "The Excel generator completed without creating a workbook.")
                }
                outputURL = workbook
                state = .succeeded
                try? CacheManager.prepareAndClean()
                refreshCacheSize()
                log = "VFX Shot List complete: \(rows.count) thumbnails and Excel workbook created."
                revealOutput()
            } catch {
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func chooseReferenceMovie() {
        let panel = NSOpenPanel()
        panel.title = "Choose Timeline Reference Movie"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            referenceMovieURL = panel.url
        }
    }

    func chooseDeliveryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Deliveries Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK { deliveryFolderURL = panel.url }
    }

    func runVFXTimeline() {
        guard let sourceURL else { return }
        if deliveryFolderURL == nil { chooseDeliveryFolder() }
        guard let deliveryFolderURL else {
            log = "VFX Timeline cancelled: no delivery folder selected."
            return
        }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxTimelineScript() else {
            state = .failed("The bundled VFX Timeline transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "VFX Timeline") else {
            log = "VFX Timeline cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "vfx-timeline")
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-vfx-timeline-\(UUID().uuidString).tsv")
        let handles = max(0, timelineHandleFrames)
        let slate = max(0, timelineSlateFrames)
        let placement = timelinePlacement.argument
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Matching VFX deliveries to naming titles..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let configText = [
                        "status\tok",
                        "delivery_folder\t\(deliveryFolderURL.path)",
                        "delivery_batch_name\t\(deliveryFolderURL.lastPathComponent)",
                        "target_event_name\t📦 Turnover",
                        "handle_frames\t\(handles)",
                        "total_handle_frames\t\(handles)",
                        "slate_frames\t\(slate)",
                        "placement_mode\t\(placement)",
                        "lane\t10",
                        "existing_event_names\t",
                        "existing_project_names\t",
                    ].joined(separator: "\n") + "\n"
                    try configText.write(to: config, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: config) }
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--config", config.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "VFX-Timeline", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "VFX Timeline completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runVFXNaming() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxNamingScript() else {
            state = .failed("The bundled VFX Naming transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        let suffix = namingMode == .auto ? "Auto Naming" : "Reset Naming"
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: suffix) else {
            log = "VFX Naming cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "vfx-naming")
        let mode = namingMode.argument
        let start = max(0, namingStart)
        let step = max(1, namingStep)
        state = .running
        outputURL = nil
        reportURL = nil
        log = namingMode == .auto ? "Numbering VFX naming titles..." : "Resetting VFX naming titles to XXXX..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                            "--mode", mode,
                            "--start", String(start),
                            "--step", String(step),
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "VFX-Naming", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "VFX Naming completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runVFXPullEDL() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.vfxPullEDLScript() else {
            state = .failed("The bundled VFX Pull EDL planner is missing.")
            return
        }
        guard let markerScriptURL = NodeRunner.autoMarkerScript() else {
            state = .failed("The bundled marker anchor transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let outputDirectory = chooseVFXPullExportDirectory(suggestedBy: sourceURL) else {
            log = "VFX Pull EDL export cancelled."
            return
        }
        let debugDirectory: URL
        do {
            debugDirectory = try createDebugJobDirectory(tool: "VFX-Pull-EDL")
        } catch {
            state = .failed("Could not prepare the debug cache: \(error.localizedDescription)")
            return
        }
        let debugSource = debugDirectory.appendingPathComponent("Source.fcpxml")
        let anchoredSource = debugDirectory.appendingPathComponent("Marker-Anchored.fcpxml")
        let markerReport = debugDirectory.appendingPathComponent("Auto-Marker.report.txt")
        let report = debugDirectory.appendingPathComponent("VFX-Pull-EDL.report.txt")
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-vfx-pull-\(UUID().uuidString).tsv")
        let handles = max(0, handleFrames)
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Building VFX Pull EDL from VFX naming titles..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: plannerSource, to: debugSource)
                    _ = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            markerScriptURL.path,
                            "--source-xml", debugSource.path,
                            "--output-xml", anchoredSource.path,
                            "--report", markerReport.path,
                            "--marker-kind", "standard",
                            "--rename-markers", "true",
                        ]
                    )
                    try "handle_frames\t\(handles)\n".write(to: config, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: config) }
                    return try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", anchoredSource.path,
                            "--config", config.path,
                            "--output-dir", outputDirectory.path,
                            "--report", report.path,
                        ]
                    )
                }.value
                let paths = parsePlannerPaths(result)
                guard let edl = paths.edl, FileManager.default.fileExists(atPath: edl.path) else {
                    throw NodeRunner.ProcessFailure(message: "The planner completed without creating an EDL file.")
                }
                outputURL = edl
                reportURL = nil
                state = .succeeded
                try? CacheManager.prepareAndClean()
                refreshCacheSize()
                log = "VFX Pull EDL completed. Marker anchors were generated privately; the Final Cut timeline was not modified."
            } catch {
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func runAutoMarker() {
        guard let sourceURL else { return }
        guard let nodeURL = NodeRunner.findNode() else {
            state = .failed("Node.js was not found. Install Node.js or configure TURNOVER_NODE_PATH.")
            return
        }
        guard let scriptURL = NodeRunner.autoMarkerScript() else {
            state = .failed("The bundled Auto Marker transformer is missing.")
            return
        }

        let plannerSource = sourceURL.pathExtension.lowercased() == "fcpxmld"
            ? sourceURL.appendingPathComponent("Info.fcpxml")
            : sourceURL
        guard let destination = chooseXMLOutputURL(for: sourceURL, suffix: "Auto Marker") else {
            log = "Auto Marker cancelled: no output location selected."
            return
        }
        let report = temporaryReportURL(tool: "auto-marker")
        let selectedKind = markerKind.argument
        let shouldRename = renameMarkers
        state = .running
        outputURL = nil
        reportURL = nil
        log = "Creating \(markerKind.rawValue) markers..."

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try await NodeRunner.run(
                        executable: nodeURL,
                        arguments: [
                            scriptURL.path,
                            "--source-xml", plannerSource.path,
                            "--output-xml", destination.path,
                            "--report", report.path,
                            "--marker-kind", selectedKind,
                            "--rename-markers", shouldRename ? "true" : "false",
                        ]
                    )
                    try await NodeRunner.prepareForFinalCutImport(executable: nodeURL, xmlURL: destination)
                    return result
                }.value
                outputURL = destination
                cacheDebugArtifacts(tool: "Auto-Marker", sourceXML: plannerSource, output: destination, report: report)
                try? FileManager.default.removeItem(at: report)
                reportURL = nil
                state = .succeeded
                log = result.isEmpty ? "Auto Marker completed." : result
                if openInFinalCut { openResultInFinalCut() }
            } catch {
                try? FileManager.default.removeItem(at: report)
                state = .failed(error.localizedDescription)
                log = error.localizedDescription
            }
        }
    }

    func openResultInFinalCut() {
        guard let outputURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let finalCutURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") {
            NSWorkspace.shared.open(
                [outputURL],
                withApplicationAt: finalCutURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    Task { @MainActor in
                        self.state = .failed("Final Cut Pro could not open the result: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            NSWorkspace.shared.open(outputURL)
        }
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.open(reportURL)
    }

    func clearCache() {
        do {
            let clearsCurrentSource = sourceURL.map { $0.path.hasPrefix(CacheManager.inboxURL.path + "/") } ?? false
            try CacheManager.clear()
            if clearsCurrentSource {
                sourceURL = nil
                outputURL = nil
                reportURL = nil
                state = .idle
            }
            refreshCacheSize()
            log = "Turnover cache cleared. User-selected source files and saved outputs were not touched."
        } catch {
            state = .failed("Could not clear the cache: \(error.localizedDescription)")
        }
    }

    private func refreshCacheSize() {
        cacheSizeText = ByteCountFormatter.string(fromByteCount: CacheManager.size(), countStyle: .file)
    }

    private func chooseXMLOutputURL(for source: URL, suffix: String) -> URL? {
        if openInFinalCut {
            guard let folder = try? createDebugJobDirectory(tool: suffix.replacingOccurrences(of: " ", with: "-")) else {
                return nil
            }
            return folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) - \(suffix).fcpxml")
        }

        let panel = NSSavePanel()
        panel.title = "Save \(suffix) FCPXML"
        panel.prompt = "Save"
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent) - \(suffix).fcpxml"
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.pathExtension.lowercased() == "fcpxml" ? url : url.appendingPathExtension("fcpxml")
    }

    nonisolated private static func formatTimecode(seconds: Double, frameDuration: Double, tcFormat: String) -> String {
        let duration = frameDuration > 0 ? frameDuration : (1.0 / 24.0)
        let fps = max(1, Int((1.0 / duration).rounded()))
        var frames = max(0, Int((seconds / duration + 0.000001).rounded(.down)))
        if tcFormat.uppercased() == "DF", fps == 30 || fps == 60 {
            let dropFrames = Int((Double(fps) * 0.0666666667).rounded())
            let framesPerMinute = (fps * 60) - dropFrames
            let framesPerTenMinutes = (fps * 600) - (dropFrames * 9)
            let tenMinuteChunks = frames / framesPerTenMinutes
            let remainder = frames % framesPerTenMinutes
            frames += (dropFrames * 9 * tenMinuteChunks)
                + (dropFrames * max(0, remainder - dropFrames) / framesPerMinute)
        }
        let ff = frames % fps
        let totalSeconds = frames / fps
        let ss = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let mm = totalMinutes % 60
        let hh = (totalMinutes / 60) % 24
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }

    private func cacheDebugArtifacts(tool: String, sourceXML: URL, output: URL, report: URL) {
        let outputIsCached = output.path.hasPrefix(CacheManager.inboxURL.path + "/")
        let folder: URL
        if outputIsCached {
            folder = output.deletingLastPathComponent()
        } else {
            guard let debugFolder = try? createDebugJobDirectory(tool: tool) else { return }
            folder = debugFolder
        }
        let manager = FileManager.default
        var items = [
            (sourceXML, folder.appendingPathComponent("Source.fcpxml")),
            (report, folder.appendingPathComponent("Report.txt")),
        ]
        if !outputIsCached {
            let outputExtension = output.pathExtension.isEmpty ? "dat" : output.pathExtension
            items.append((output, folder.appendingPathComponent("Output.\(outputExtension)")))
        }
        for (source, destination) in items where manager.fileExists(atPath: source.path) {
            guard source.standardizedFileURL != destination.standardizedFileURL else { continue }
            try? manager.copyItem(at: source, to: destination)
        }
        try? CacheManager.prepareAndClean()
        refreshCacheSize()
    }

    private func temporaryReportURL(tool: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turnover-\(tool)-\(UUID().uuidString).report.txt")
    }

    private func uniqueSidecarURL(for source: URL, suffix: String, extension ext: String) -> URL {
        uniqueSidecarURL(
            in: source.deletingLastPathComponent(),
            baseName: source.deletingPathExtension().lastPathComponent,
            suffix: suffix,
            extension: ext
        )
    }

    private func uniqueSidecarURL(
        in folder: URL,
        baseName: String,
        suffix: String,
        extension ext: String
    ) -> URL {
        folder.appendingPathComponent("\(baseName) - \(suffix).\(ext)")
    }

    private func createDebugJobDirectory(tool: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = CacheManager.inboxURL
            .appendingPathComponent("Debug", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date()))-\(tool)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func chooseVFXPullExportDirectory(suggestedBy source: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Pull EDL Export Folder"
        panel.prompt = "Export"
        panel.message = "Only the EDL will be saved here. Debug TSV and reports stay in Turnover cache."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseMarkerExportDirectory(suggestedBy source: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Marker Export Folder"
        panel.prompt = "Export"
        panel.message = "Turnover will save the selected marker export format in this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func parsePlannerPaths(_ output: String) -> (edl: URL?, csv: URL?, txt: URL?, report: URL?) {
        let jsonLine = output.split(separator: "\n").last.map(String.init) ?? output
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        let edl = (object["edl_path"] as? String).map(URL.init(fileURLWithPath:))
        let csv = (object["csv_path"] as? String).map(URL.init(fileURLWithPath:))
        let txt = (object["txt_path"] as? String).map(URL.init(fileURLWithPath:))
        let report = (object["report_path"] as? String).map(URL.init(fileURLWithPath:))
        return (edl, csv, txt, report)
    }

    nonisolated private static func shotListManifestRows(at url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard lines.count >= 2 else {
            throw NodeRunner.ProcessFailure(message: "The VFX Shot List manifest has no marker rows.")
        }
        let headers = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map { line in
            let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                row[header] = unescapeTSV(index < values.count ? values[index] : "")
            }
            return row
        }
    }

    private func chooseShotListExportDirectory(suggestedBy source: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose VFX Shot List Export Folder"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.path.hasPrefix(CacheManager.inboxURL.path + "/")
            ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            : source.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func uniqueShotListResultFolder(in parent: URL, projectName: String) -> URL {
        let base = "VFX Shot List - \(sanitizeFilename(projectName))"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func sanitizeFilename(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: #"[<>:\"/\\|?*]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Project" : clean
    }

    nonisolated private static func unescapeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "\u{0000}")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "\\")
    }

    private var finalCutPasteboardTypes: [String] {
        (8...14).reversed().map { "com.apple.finalcutpro.xml.v1-\($0)" }
            + ["com.apple.finalcutpro.xml"]
    }

    private func storeFinalCutDrop(_ data: Data) throws -> URL {
        guard let xml = String(data: data, encoding: .utf8), xml.contains("<fcpxml") else {
            throw NodeRunner.ProcessFailure(message: "The dropped Final Cut Pro payload is not valid UTF-8 FCPXML.")
        }
        let projectName = xml.firstMatch(for: #"<project\b[^>]*\bname="([^"]+)""#) ?? "Final Cut Project"
        let safeName = projectName
            .replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inbox = CacheManager.inboxURL
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var destination = inbox.appendingPathComponent("\(safeName).fcpxml")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = inbox.appendingPathComponent("\(safeName) \(index).fcpxml")
            index += 1
        }
        let normalizedXML = normalizeFinalCutDropText(xml)
        guard let normalizedData = normalizedXML.data(using: .utf8) else {
            throw NodeRunner.ProcessFailure(message: "The normalized Final Cut Pro project is not valid UTF-8.")
        }
        try normalizedData.write(to: destination, options: .atomic)
        refreshCacheSize()
        return destination
    }

    private func normalizeFinalCutDropText(_ xml: String) -> String {
        guard let textStyleExpression = try? NSRegularExpression(
            pattern: #"<text-style\b[^>]*>[\s\S]*?</text-style>"#
        ), let continuationIndent = try? NSRegularExpression(pattern: #"(\r?\n) {8}"#) else {
            return xml
        }

        var normalized = xml
        let matches = textStyleExpression.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: normalized) else { continue }
            let block = String(normalized[range])
            let cleanBlock = continuationIndent.stringByReplacingMatches(
                in: block,
                range: NSRange(block.startIndex..., in: block),
                withTemplate: "$1"
            )
            normalized.replaceSubrange(range, with: cleanBlock)
        }
        return normalized
    }
}

private extension String {
    func firstMatch(for pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
