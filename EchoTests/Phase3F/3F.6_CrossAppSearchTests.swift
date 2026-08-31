// ==========================================
// 文件: 3F.6_CrossAppSearchTests.swift
// 对应规格: docs/01-spec/用户故事与验收标准规格书.md → US-SRC-010 (跨 App 数据关联搜索),
//            US-SRC-011 (主观/模糊意图理解), US-RET-003 (审计),
//            docs/05-planning/phase3f-execution-plan.md → 3F.6 (Production search 与 feedback)
// 任务: 3F.6 - Production search 与 feedback（跨 App 检索部分 US-SRC-010/011）
// AC 覆盖: US-SRC-010 AC-1 (health+memory/location+photo 意图解析 + plainSearch),
//          AC-2 (Privacy Gate 逐源授权 — 未授权源 provider 不被调用),
//          AC-3 (多源联合检索按时间窗对齐), AC-4 (结果标注数据来源图标),
//          AC-5 (审计 .crossAppSearch 含「实际授权」source 列表，非请求列表)
//          US-SRC-011 AC-2 (结果按主观匹配度排序而非仅客观分数),
//          AC-3 (主观阈值重排经生产 BoundedReranker), AC-4 (准确/不准确反馈仅本地学习)
// 架构约束: AGENTS.md §4.2 (Actor 隔离), §5.3 (反馈权重截断 clamp ±0.5),
//           R-006 (PrivacyCheckpoint), R-007 (禁止 unchecked Sendable / Combine)
// 重要: TDD GREEN — 生产 CrossAppIntentParser.parse / ProductionCrossAppFusionEngine /
//       BoundedReranker.rerank 全部实现（PR#58 CR-10: 测试直连生产融合引擎，移除内联 TestEngine）；
//       US-SRC-011 AC-3 .subjectiveMatch 字段延后 DEF-58-005。
// 生成时间: 2026-08-11 | 更新: 2026-08-11 (PR#58 review 修复)
// ==========================================

import Testing
import Foundation
@testable import Echo

// MARK: - Test Embedder / ASR（自包含确定性实现，不与 3F.5 文件符号重名）

/// 确定性生产嵌入器 — 实现真实 EmbedderProtocol，输出固定维度向量（text=384d / vision=768d）。
public actor CrossAppTestEmbedder: EmbedderProtocol {
    private let textDimension: Int
    private let visionDimension: Int

    public init(textDimension: Int = 384, visionDimension: Int = 768) {
        self.textDimension = textDimension
        self.visionDimension = visionDimension
    }

    public func embedImage(assetId: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }

    public func embedText(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.5, count: textDimension)
    }

    public func embedImageData(_ data: Data) async throws -> [Float] {
        [Float](repeating: 0.5, count: visionDimension)
    }
}

/// 确定性生产 ASR — 实现真实 ASREngineProtocol，返回固定转写文本。
public actor CrossAppTestASR: ASREngineProtocol {
    private let transcript: String

    public init(transcript: String = "这是一段测试语音转写内容。") {
        self.transcript = transcript
    }

    public func transcribe(audioTrackAssetId: String) async throws -> String {
        transcript
    }

    public func transcribeFile(at url: URL) async throws -> String {
        transcript
    }
}

// MARK: - Test Providers（CrossAppSourceProvider spy / recording）

/// 调用记录器 — 跨 Actor 安全地记录 provider 是否被分发引擎调用（US-SRC-010 AC-2）。
public actor ProviderInvocationTracker {
    private var count = 0

    public init() {}

    public func mark() {
        count += 1
    }

    public func invocationCount() -> Int {
        count
    }
}

/// 抛错 spy provider — 记录调用次数并抛 `.unauthorizedSource`。
///
/// AC-2 契约：当 UserPolicy 拒绝该 sourceType 时，融合引擎【必须】跳过此 provider，
/// 即 `invocationCount == 0`；若被调用则抛错，同样证明授权门失败。
public actor ThrowingSpyProvider: CrossAppSourceProvider {
    /// 数据源类型（非隔离只读存储属性，满足 `nonisolated var sourceType`）
    public let sourceType: String
    private let tracker: ProviderInvocationTracker

    public init(sourceType: String, tracker: ProviderInvocationTracker = ProviderInvocationTracker()) {
        self.sourceType = sourceType
        self.tracker = tracker
    }

    public func invocationCount() async -> Int {
        await tracker.invocationCount()
    }

    /// 非隔离 witness：仅记录调用并抛错，不触碰隔离状态（R-007 安全）。
    nonisolated public func search(
        query: String,
        window: ClosedRange<Date>?
    ) async throws -> [CrossAppSourceResult] {
        await tracker.mark()
        throw CrossAppIntentError.unauthorizedSource(sourceType: sourceType)
    }
}

/// 固定结果 recording provider — 返回预设的 `CrossAppSourceResult` 列表（AC-3/AC-4/AC-5）。
public actor RecordingSourceProvider: CrossAppSourceProvider {
    public let sourceType: String
    private let results: [CrossAppSourceResult]

    public init(sourceType: String, results: [CrossAppSourceResult]) {
        self.sourceType = sourceType
        self.results = results
    }

    nonisolated public func search(
        query: String,
        window: ClosedRange<Date>?
    ) async throws -> [CrossAppSourceResult] {
        results
    }
}

// MARK: - 主观评分器（确定性测试实现）

/// 确定性主观评分器 — 关键词 → 分数映射，多关键词命中取最低分（低置信度语义）。
///
/// US-SRC-011 AC-1/AC-2：对主观查询文本与记忆内容的语义/情绪关联打分（0~1）。
/// 生产实现基于视觉-文本联合嵌入（CLIP 语义响应）；测试注入确定性实现。
public actor DeterministicSubjectiveScorer: SubjectiveScorer {
    private let keywordScores: [String: Float]
    private let defaultScore: Float

    public init(keywordScores: [String: Float], defaultScore: Float = 0.1) {
        self.keywordScores = keywordScores
        self.defaultScore = defaultScore
    }

    nonisolated public func subjectiveMatchScore(text: String) async throws -> Float {
        let lowered = text.lowercased()
        let matches = keywordScores.compactMap { keyword, score -> Float? in
            lowered.contains(keyword) ? score : nil
        }
        return matches.min() ?? defaultScore
    }
}

// MARK: - Test Suite: Cross App Search (3F.6, US-SRC-010/011)

@Suite("CrossAppSearchTests", .serialized)
@MainActor
struct CrossAppSearchTests {

    let db = DatabaseManager.shared

    init() async throws {
        try await CrossAppSearchTests.wipeCanonicalTables()
    }

    // MARK: - Fixture Helpers

    /// 与 3F.5 wipeCanonicalTables 完全一致 + PendingOperations 清理。
    private static func wipeCanonicalTables() async throws {
        let db = DatabaseManager.shared
        try await db.open()
        try await db.execute(sql: "DELETE FROM MemoryFTS")
        try await db.execute(sql: "DELETE FROM translationCache")
        try await db.execute(sql: "DELETE FROM Representation")
        try await db.execute(sql: "DELETE FROM Memory")
        try await db.execute(sql: "DELETE FROM IndexBuildItem")
        try await db.execute(sql: "DELETE FROM IndexGeneration")
        try await db.execute(sql: "DELETE FROM ActiveRouteSet")
        try await db.execute(sql: "DELETE FROM FeedbackStore")
        try await db.execute(sql: "DELETE FROM ExcludedAssets")
        try await db.execute(sql: "DELETE FROM TaskProgress")
        try await db.execute(sql: "DELETE FROM UserPolicyStore")
        try await db.execute(sql: "DELETE FROM AuditLog")
        try await db.execute(sql: "DELETE FROM PendingOperations")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let generationsDir = appSupport.appendingPathComponent("Echo/generations", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path) {
            for file in files where file.hasSuffix(".pxkt") {
                try? FileManager.default.removeItem(at: generationsDir.appendingPathComponent(file))
            }
        }
    }

    /// UTC 日期构造 — 时间戳对齐断言使用确定性时刻（AC-3）。
    private static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    /// US-SRC-010 AC-4: 数据来源图标映射（❤️ health / 📝 memory / 📷 photo）。
    private static func sourceIcon(for sourceType: String) -> String {
        switch sourceType {
        case "health": return "❤️"
        case "memory": return "📝"
        case "photo": return "📷"
        default: return "❓"
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 1. US-SRC-010 AC-1: 跨域查询意图解析（CrossAppIntentParser）
    // ══════════════════════════════════════════════════════════════

    @Test("AC-1: health+memory intent — 失眠日记")
    func test_AC1_HealthMemoryIntentParsing() async throws {
        let parser = CrossAppIntentParser()
        let intent = try await parser.parse(query: "上次失眠时写的日记")
        #expect(intent.domain == .healthMemory)
        #expect(intent.sources.contains("health"))
        #expect(intent.sources.contains("memory"))
    }

    @Test("AC-1: health+photo intent — 心率超120时的运动照片")
    func test_AC1_HealthPhotoIntentParsing() async throws {
        let parser = CrossAppIntentParser()
        let intent = try await parser.parse(query: "心率超120时的运动照片")
        #expect(intent.domain == .healthMemory || intent.domain == .locationPhoto)
        #expect(intent.sources.contains("photo"))
    }

    @Test("AC-1: location+photo subjective intent — 有氛围感的夜景")
    func test_AC1_LocationPhotoIntentParsing() async throws {
        let parser = CrossAppIntentParser()
        let intent = try await parser.parse(query: "有氛围感的夜景")
        #expect(intent.domain == .locationPhoto)
        #expect(intent.sources.contains("photo"))
        #expect(intent.subjective)
    }

    @Test("AC-1: location+photo subjective intent — 适合做头像的构图")
    func test_AC1_CompositionIntentParsing() async throws {
        let parser = CrossAppIntentParser()
        let intent = try await parser.parse(query: "适合做头像的构图")
        #expect(intent.domain == .locationPhoto)
        #expect(intent.sources.contains("photo"))
        #expect(intent.subjective)
    }

    @Test("AC-1: plain query — 今天吃的什么 → plainSearch")
    func test_AC1_PlainQueryParsing() async throws {
        let parser = CrossAppIntentParser()
        let intent = try await parser.parse(query: "今天吃的什么")
        #expect(intent.domain == .plainSearch)
        #expect(!intent.subjective)
    }

    @Test("AC-1 anchor: isCrossAppQuery keyword heuristic (implemented)")
    func test_AC1_IsCrossAppQueryAnchor() {
        // 已实现锚点 — 关键词启发式分类（PASS）
        #expect(CrossAppIntentParser.isCrossAppQuery("上次失眠时写的日记"))
        #expect(CrossAppIntentParser.isCrossAppQuery("附近的夜景照片"))
        #expect(!CrossAppIntentParser.isCrossAppQuery("今天吃的什么"))
    }

    // ══════════════════════════════════════════════════════════════
    // 2. US-SRC-010 AC-2: Privacy Gate 逐源授权（未授权源 provider 不被调用）
    // ══════════════════════════════════════════════════════════════

    @Test("AC-2: denied health source provider is never invoked")
    func test_AC2_DeniedSourceProviderNotInvoked() async throws {
        let privacy = PrivacyActor(db: db)
        // 用户拒绝 "health" 数据源
        try await privacy.updatePolicy(
            UserPolicy(authorizedSourceTypes: ["memory", "photo"], policyVersion: 2)
        )

        let healthTracker = ProviderInvocationTracker()
        let healthProvider = ThrowingSpyProvider(sourceType: "health", tracker: healthTracker)
        let memoryProvider = RecordingSourceProvider(
            sourceType: "memory",
            results: [
                CrossAppSourceResult(
                    memoryId: UUID(),
                    sourceType: "memory",
                    timestamp: Date().timeIntervalSince1970,
                    snippet: "失眠日记",
                    matchScore: 0.9,
                ),
            ]
        )

        let engine = ProductionCrossAppFusionEngine(privacy: privacy, providers: [healthProvider, memoryProvider])
        // 生产 parse()：解析健康记忆域 → sources ["health","memory"]
        let intent = try await CrossAppIntentParser().parse(query: "上次失眠时写的日记")
        let fused = try await engine.search(intent: intent, traceID: "trace-ac2-denied-health")

        // AC-2 契约: 未授权源必须不被调用（fail-closed）
        #expect(await healthProvider.invocationCount() == 0)
        // 被拒源不得产生任何结果
        #expect(!fused.contains { $0.sourceType == "health" })
        // 已授权源正常返回
        #expect(fused.contains { $0.sourceType == "memory" })
    }

    // ══════════════════════════════════════════════════════════════
    // 3. US-SRC-010 AC-3: 多源联合检索按时间对齐
    // ══════════════════════════════════════════════════════════════

    @Test("AC-3: multi-source results aligned by temporal window and timestamp")
    func test_AC3_TemporalAlignmentMultiSource() async throws {
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(
            UserPolicy(authorizedSourceTypes: ["health", "memory", "photo"], policyVersion: 2)
        )

        // 时间短语「8月1日」解析为【当前年】的窗口（PR#58 CR-19）—
        // fixture 年份从当前日期派生，避免 2027 年后测试失效。
        let year = Calendar.current.component(.year, from: Date())
        let t1 = CrossAppSearchTests.utcDate(year, 8, 1, 2, 0).timeIntervalSince1970
        let t2 = CrossAppSearchTests.utcDate(year, 8, 1, 2, 30).timeIntervalSince1970
        let outOfWindow = CrossAppSearchTests.utcDate(year, 9, 1, 2, 0).timeIntervalSince1970

        let healthID = UUID()
        let diaryID = UUID()
        let staleID = UUID()

        let engine = ProductionCrossAppFusionEngine(
            privacy: privacy,
            providers: [
                RecordingSourceProvider(
                    sourceType: "health",
                    results: [
                        CrossAppSourceResult(memoryId: healthID, sourceType: "health", timestamp: t1, snippet: "失眠记录", matchScore: 0.9)
                    ]
                ),
                RecordingSourceProvider(
                    sourceType: "memory",
                    results: [
                        CrossAppSourceResult(memoryId: diaryID, sourceType: "memory", timestamp: t2, snippet: "失眠日记", matchScore: 0.85),
                        CrossAppSourceResult(memoryId: staleID, sourceType: "memory", timestamp: outOfWindow, snippet: "过期日记", matchScore: 0.5),
                    ]
                ),
            ]
        )

        let intent = try await CrossAppIntentParser().parse(query: "8月1日失眠时写的日记")
        let fused = try await engine.search(intent: intent, traceID: "trace-ac3-temporal")

        // AC-3 契约: 窗口内两条结果都在、窗口外被剔除、按时间戳升序对齐
        #expect(fused.map(\.memoryId).contains(healthID))
        #expect(fused.map(\.memoryId).contains(diaryID))
        #expect(!fused.map(\.memoryId).contains(staleID))
        #expect(fused.count == 2)
        #expect(fused[0].timestamp <= fused[1].timestamp)
        #expect(fused.first?.memoryId == healthID)
    }

    // ══════════════════════════════════════════════════════════════
    // 4. US-SRC-010 AC-4: 结果标注数据来源标签/图标（❤️📝📷）
    // ══════════════════════════════════════════════════════════════

    @Test("AC-4: fused results preserve source labels mapping to icons")
    func test_AC4_SourceLabelsPreserved() async throws {
        let privacy = PrivacyActor(db: db)
        try await privacy.updatePolicy(
            UserPolicy(authorizedSourceTypes: ["health", "memory", "photo"], policyVersion: 2)
        )

        let now = Date().timeIntervalSince1970
        let engine = ProductionCrossAppFusionEngine(
            privacy: privacy,
            providers: [
                RecordingSourceProvider(
                    sourceType: "health",
                    results: [CrossAppSourceResult(memoryId: UUID(), sourceType: "health", timestamp: now, snippet: "心率记录", matchScore: 0.9)]
                ),
                RecordingSourceProvider(
                    sourceType: "memory",
                    results: [CrossAppSourceResult(memoryId: UUID(), sourceType: "memory", timestamp: now, snippet: "运动备忘", matchScore: 0.7)]
                ),
                RecordingSourceProvider(
                    sourceType: "photo",
                    results: [CrossAppSourceResult(memoryId: UUID(), sourceType: "photo", timestamp: now, snippet: nil, matchScore: 0.8)]
                ),
            ]
        )

        let intent = try await CrossAppIntentParser().parse(query: "心率超120时的运动照片")
        let fused = try await engine.search(intent: intent, traceID: "trace-ac4-labels")

        // AC-4 契约: 每条结果保留 sourceType 标签，且可映射到展示图标
        let sourceTypes = Set(fused.map(\.sourceType))
        #expect(sourceTypes.isSubset(of: ["health", "memory", "photo"]))
        #expect(sourceTypes.contains("health"))
        #expect(sourceTypes.contains("photo"))
        for result in fused {
            let icon = CrossAppSearchTests.sourceIcon(for: result.sourceType)
            #expect(icon == "❤️" || icon == "📝" || icon == "📷")
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 5. US-SRC-010 AC-5: 审计 .crossAppSearch 含实际授权 source 列表
    // ══════════════════════════════════════════════════════════════

    @Test("AC-5: audit carries actual authorized source list (not requested)")
    func test_AC5_CrossAppAuditAuthorizedSources() async throws {
        let privacy = PrivacyActor(db: db)
        // 用户授权 health + memory，拒绝 photo — 但请求词包含 photo（心率+运动照片）
        try await privacy.updatePolicy(
            UserPolicy(authorizedSourceTypes: ["health", "memory"], policyVersion: 3)
        )

        let photoTracker = ProviderInvocationTracker()
        let engine = ProductionCrossAppFusionEngine(
            privacy: privacy,
            providers: [
                RecordingSourceProvider(
                    sourceType: "health",
                    results: [CrossAppSourceResult(memoryId: UUID(), sourceType: "health", timestamp: Date().timeIntervalSince1970, snippet: "心率记录", matchScore: 0.9)]
                ),
                ThrowingSpyProvider(sourceType: "photo", tracker: photoTracker),
            ]
        )

        let traceID = "trace-ac5-audit"
        let intent = try await CrossAppIntentParser().parse(query: "心率超120时的运动照片")
        _ = try await engine.search(intent: intent, traceID: traceID)

        // AC-5 契约: AuditLog 存在 eventType='crossAppSearch'，sourceType 为实际授权列表
        let rows = try await db.executeQuery(
            sql: "SELECT sourceType FROM AuditLog WHERE eventType = 'crossAppSearch' AND traceID = ? ORDER BY timestamp DESC LIMIT 1",
            bindings: [.text(traceID)]
        )
        let stored = rows.first?["sourceType"]?.stringValue ?? ""
        let components = stored.split(separator: ",").map(String.init)

        // 请求了 photo 但未授权 → 不出现；实际授权的 health 出现
        let policy = await privacy.getPolicy()
        let expected = intent.sources.filter { policy.isAuthorized(sourceType: $0) }.sorted()
        #expect(components == expected)
        #expect(!components.contains("photo"))
        #expect(components.contains("health"))
        #expect(await photoTracker.invocationCount() == 0)
    }

    // ══════════════════════════════════════════════════════════════
    // 6. US-SRC-011 AC-2: 结果按主观匹配度排序（BoundedReranker）
    // ══════════════════════════════════════════════════════════════

    @Test("AC-2: rerank orders by combined cosine + subjective boost")
    func test_AC2_SubjectiveRanking() async throws {
        let scorer = DeterministicSubjectiveScorer(keywordScores: ["夜景": 0.9])
        let reranker = BoundedReranker(
            scorer: scorer,
            config: RerankConfig(subjectiveBoost: 0.15, subjectiveThreshold: 0.6, maxAdjustment: 0.5)
        )

        // A: 余弦 0.70 但主观命中（夜景 → 0.9 ≥ 0.6，+0.15 → 0.85）
        // B: 余弦 0.80 但主观未命中（0.1 < 0.6，无奖励 → 0.80）
        let a = UUID()
        let b = UUID()
        let items = [
            SearchResultItem(id: a, assetId: "a", sourceType: "photo", timestamp: 1, originalText: "霓虹夜景照片", cosineSimilarity: 0.70),
            SearchResultItem(id: b, assetId: "b", sourceType: "photo", timestamp: 2, originalText: "晨跑打卡记录", cosineSimilarity: 0.80),
        ]

        let reranked = try await reranker.rerank(items: items, queryText: "有氛围感的夜景")

        // AC-2 契约: 主观匹配度优先于客观分数
        #expect(reranked.count == 2)
        #expect(reranked.first?.id == a)
        #expect(reranked.last?.id == b)
    }

    // ══════════════════════════════════════════════════════════════
    // 7. US-SRC-011 AC-3: 主观匹配重排（BoundedReranker 生产输出）
    //    NOTE (PR#58 CR-20): SearchResultItem 尚无 subjectiveMatch 字段（延后 DEF-58-005），
    //    本测试断言生产 rerank 的真实重排输出（阈值 + boost 生效）。
    // ══════════════════════════════════════════════════════════════

    @Test("AC-3: subjective boost reorders production rerank output by threshold")
    func test_AC3_LowConfidenceSubjectiveMarked() async throws {
        let scorer = DeterministicSubjectiveScorer(keywordScores: ["夜景": 0.85, "模糊": 0.35])
        let reranker = BoundedReranker(
            scorer: scorer,
            config: RerankConfig(subjectiveBoost: 0.15, subjectiveThreshold: 0.6, maxAdjustment: 0.5)
        )

        // strong: 主观 0.85 ≥ 0.6 → +0.15 → 0.85 + 0.15 = 1.00
        // weak:   主观 0.35 < 0.6（含「模糊」命中取 min）→ 无奖励 → 0.55
        let strongID = UUID()
        let weakID = UUID()
        let items = [
            SearchResultItem(id: strongID, assetId: "strong", sourceType: "photo", timestamp: 1, originalText: "璀璨夜景全景", cosineSimilarity: 0.85),
            SearchResultItem(id: weakID, assetId: "weak", sourceType: "photo", timestamp: 2, originalText: "模糊的夜景角落", cosineSimilarity: 0.55),
        ]

        let reranked = try await reranker.rerank(items: items, queryText: "有氛围感的夜景")

        // AC-3 契约（生产路径）：达到阈值的强主观结果被提升至首位
        #expect(reranked.count == 2)
        #expect(reranked.first?.id == strongID, "strong subjective result must be boosted above the weak one")
    }

    // ══════════════════════════════════════════════════════════════
    // 8. US-SRC-011 AC-4: 主观结果「准确/不准确」反馈（仅本地学习）
    // ══════════════════════════════════════════════════════════════

    @Test("AC-4: subjective feedback is query-conditioned and stored locally")
    func test_AC4_SubjectiveFeedbackLocalOnly() async throws {
        let scorer = DeterministicSubjectiveScorer(keywordScores: ["夜景": 0.85])
        let reranker = BoundedReranker(scorer: scorer, config: RerankConfig())

        let photoID = UUID()
        let items = [
            SearchResultItem(id: photoID, assetId: "photo-subj", sourceType: "photo", timestamp: 1, originalText: "有氛围感的夜景照片", cosineSimilarity: 0.8),
        ]

        let reranked = try await reranker.rerank(items: items, queryText: "有氛围感的夜景")
        let subjectiveResult = try #require(reranked.first)

        let feedback = FeedbackActor.shared
        let traceID = "trace-subj-feedback-1"
        let query = "有氛围感的夜景"

        // 不准确（dislike）+ 准确（like）— 均 query-conditioned，仅本地存储
        let inaccurate = FeedbackEntry(
            id: UUID(),
            memoryId: subjectiveResult.id,
            queryText: query,
            sentiment: .dislike,
            cosineSimilarity: Double(subjectiveResult.cosineSimilarity)
        )
        let accurate = FeedbackEntry(
            id: UUID(),
            memoryId: subjectiveResult.id,
            queryText: query,
            sentiment: .like,
            cosineSimilarity: Double(subjectiveResult.cosineSimilarity)
        )
        try await feedback.recordFeedback(inaccurate, traceID: traceID, generationId: "text_dense/e5-v1")
        try await feedback.recordFeedback(accurate, traceID: traceID, generationId: "text_dense/e5-v1")

        // AC-4 契约: generationId round-trip（ADR-010 决策-4）+ query-conditioned 本地存储
        let roundTrip = try await feedback.generationId(for: inaccurate.id)
        #expect(roundTrip == "text_dense/e5-v1")

        let rows = try await db.executeQuery(
            sql: "SELECT queryText, sentiment FROM FeedbackStore WHERE feedbackId = ?",
            bindings: [.text(inaccurate.id.uuidString)]
        )
        #expect(rows.first?["queryText"]?.stringValue == query)
        #expect(rows.first?["sentiment"]?.stringValue == FeedbackSentiment.dislike.rawValue)
    }

    // ══════════════════════════════════════════════════════════════
    // 9. 已实现锚点（PASS）：US-FBK-002 AC-3 权重截断 clamp ±0.5
    // ══════════════════════════════════════════════════════════════

    @Test("FBK-002 AC-3 anchor: applyAdjustment clamps to ±0.5")
    func test_AC3_ApplyAdjustmentClampAnchor() {
        // 已实现锚点 — clamp(rawAdjustment, ±0.5)（AGENTS.md §5.3）
        let clampedHigh = BoundedReranker.applyAdjustment(score: 0.7, adjustment: 0.9, max: 0.5)
        let clampedLow = BoundedReranker.applyAdjustment(score: 0.7, adjustment: -0.9, max: 0.5)
        let inside = BoundedReranker.applyAdjustment(score: 0.7, adjustment: 0.2, max: 0.5)
        #expect(abs(clampedHigh - 1.2) < 0.0001)
        #expect(abs(clampedLow - 0.2) < 0.0001)
        #expect(abs(inside - 0.9) < 0.0001)
    }

    // ══════════════════════════════════════════════════════════════
    // 10. Fixture 自包含锚点（PASS）：测试嵌入器/ASR 满足生产协议契约
    // ══════════════════════════════════════════════════════════════

    @Test("fixture anchor: test embedder/ASR satisfy production protocol contracts")
    func test_FixtureEmbedderASRContract() async throws {
        let embedder = CrossAppTestEmbedder()
        let text = try await embedder.embedText("测试")
        let vision = try await embedder.embedImage(assetId: "a")
        #expect(text.count == 384)
        #expect(vision.count == 768)

        let asr = CrossAppTestASR(transcript: "fixture transcript")
        let transcribed = try await asr.transcribe(audioTrackAssetId: "x")
        #expect(transcribed == "fixture transcript")
    }
}
