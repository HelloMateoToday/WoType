// TranslationError.swift — 失败分类。照 FluentRead 的 freeRoutingPolicy：HTTP 状态和各家的业务错误码
// 归成「请求错 / 额度用完 / 被封 / 限流 / 暂时不可用」，备选池按类别冷却。

import Foundation

public enum TranslationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 这家不支持这个语言方向
    case unsupported
    /// 请求本身有问题（这段文字、这个方向）：不冷却，换下一家
    case request(status: Int?, message: String)
    /// 额度用完：冷却 24 小时
    case quota(message: String)
    /// 被拒绝、接口没了（401/403/404/410）：冷却 6 小时起
    case blocked(status: Int?, message: String)
    /// 限流（429）：冷却 5 分钟起，有 Retry-After 就听它的
    case rateLimited(retryAfter: TimeInterval?)
    /// 服务暂时不行、网络错、回包看不懂：冷却 60 秒起
    case unavailable(message: String)
    /// 单次超时
    case timeout
    case cancelled
    /// 备选池里每家都失败了（家名 → 原因）
    case allFailed([String: String])

    public var description: String {
        switch self {
        case .unsupported: "不支持这个语言方向"
        case .request(let status, let message): "请求错误\(status.map { "（\($0)）" } ?? "")：\(message)"
        case .quota(let message): "额度用完：\(message)"
        case .blocked(let status, let message): "被拒绝\(status.map { "（\($0)）" } ?? "")：\(message)"
        case .rateLimited(let retryAfter): "限流" + (retryAfter.map { "，\(Int($0)) 秒后再试" } ?? "")
        case .unavailable(let message): "暂时不可用：\(message)"
        case .timeout: "超时"
        case .cancelled: "已取消"
        case .allFailed(let failures):
            "全部失败：" + failures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "；")
        }
    }

    /// HTTP 状态码 → 分类（照 FluentRead 的 classifyFreeFailure）
    static func http(_ status: Int, retryAfter: TimeInterval? = nil, message: String = "") -> TranslationError {
        let text = message.isEmpty ? "HTTP \(status)" : message
        switch status {
        case 402, 456: return .quota(message: text)
        case 401, 403, 404, 410: return .blocked(status: status, message: text)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 408: return .unavailable(message: text)
        case 400..<500: return .request(status: status, message: text)
        default: return .unavailable(message: text)
        }
    }

    /// 回包结构不对：多半是接口改了，按暂时不可用冷却
    static func invalidResponse(_ provider: String) -> TranslationError {
        .unavailable(message: "\(provider)返回内容无效")
    }
}
