//
//  DateCandidates.swift
//  WoType
//
//  万象的日期、时间候选展开后的各种格式（engine/core 的 wotype_session_set_date_formats）。
//  照微信输入法 2026-11-13 实测：riqi / rq 出 7 种日期，shijian / sj 出 4 种时间。
//

import Foundation

enum DateCandidates {
    /// kind 0 日期、1 时间（和 Rust 的 DateKind 一致）
    static func formats(kind: UInt32, date: Date = Date()) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let (y, m, d) = (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let padded = String(format: "%04d-%02d-%02d", y, m, d)
        if kind == 1 {
            return [
                "\(y)年\(m)月\(d)日\(time)",
                "\(padded) \(time)",
                padded.replacingOccurrences(of: "-", with: "") + time.replacingOccurrences(of: ":", with: ""),
                time,
            ]
        }
        var result = [
            "\(y)年\(m)月\(d)日",
            padded,
            padded.replacingOccurrences(of: "-", with: "/"),
            padded.replacingOccurrences(of: "-", with: "."),
            padded.replacingOccurrences(of: "-", with: ""),
            "\(digits(y))年\(number(m))月\(number(d))日",
        ]
        if let lunar = lunar(date) { result.append(lunar) }
        return result
    }

    private static let chineseDigits = Array("〇一二三四五六七八九")

    /// 逐位写：2026 → 二〇二六
    private static func digits(_ n: Int) -> String {
        String(String(n).compactMap { $0.wholeNumberValue.map { chineseDigits[$0] } })
    }

    /// 1～31 的读法：11 → 十一，20 → 二十
    private static func number(_ n: Int) -> String {
        switch n {
        case ..<10: return String(chineseDigits[n])
        case 10: return "十"
        case 11..<20: return "十" + String(chineseDigits[n - 10])
        default: return String(chineseDigits[n / 10]) + "十" + (n % 10 == 0 ? "" : String(chineseDigits[n % 10]))
        }
    }

    /// 农历：丙午[马]年十月初五（照微信）。月份闰月前面加「闰」
    private static func lunar(_ date: Date) -> String? {
        let calendar = Calendar(identifier: .chinese)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥")
        let zodiac = Array("鼠牛虎兔龙蛇马羊猴鸡狗猪")
        let index = (year - 1) % 60
        let leap = calendar.dateComponents([.isLeapMonth], from: date).isLeapMonth == true ? "闰" : ""
        let monthName = month == 1 ? "正" : number(month)
        let dayName = switch day {
        case ...10: "初" + number(day)
        case 20: "二十"
        case 21..<30: "廿" + String(chineseDigits[day - 20])
        case 30: "三十"
        default: number(day)
        }
        return "\(stems[index % 10])\(branches[index % 12])[\(zodiac[index % 12])]年\(leap)\(monthName)月\(dayName)"
    }
}
