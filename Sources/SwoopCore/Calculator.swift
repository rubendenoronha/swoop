// SPDX-License-Identifier: MIT
import Foundation

/// Inline calculator: arithmetic (+ - * / ^ %, parentheses, functions, constants)
/// and unit conversions ("10 km to mi", "72 f in c", "1.5 GB to MB").
/// No currencies: those need live rates and a network call, which Swoop avoids.
public enum CalcResult: Equatable {
    case number(Double)
    case conversion(value: Double, unit: String, from: Double, fromUnit: String)

    public var value: Double {
        switch self {
        case .number(let v): return v
        case .conversion(let v, _, _, _): return v
        }
    }

    /// Text shown in the launcher and copied on Enter.
    public var display: String {
        switch self {
        case .number(let v): return Calculator.format(v)
        case .conversion(let v, let u, _, _): return "\(Calculator.format(v)) \(u)"
        }
    }
}

public enum Calculator {
    /// nil when the text isn't a calculation (plain words, a bare number, empty).
    public static func evaluate(_ input: String) -> CalcResult? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if let conv = UnitConverter.convert(text) { return conv }
        // A bare number is not a calculation worth showing.
        if Double(text.replacingOccurrences(of: ",", with: "")) != nil { return nil }
        guard text.contains(where: { "+-*/^%()×÷!".contains($0) }) || startsWithFunction(text) else { return nil }
        var p = Parser(text)
        guard let v = p.parse(), v.isFinite else { return nil }
        return .number(v)
    }

    private static func startsWithFunction(_ t: String) -> Bool {
        let lower = t.lowercased()
        return Parser.functions.keys.contains { lower.hasPrefix($0 + "(") } || lower == "pi" || lower == "e"
    }

    public static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        if abs(v) >= 1e15 || (abs(v) < 1e-6 && v != 0) {
            f.numberStyle = .scientific
            f.maximumFractionDigits = 6
        }
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Recursive-descent parser. Grammar:
    ///   expr   := term (('+'|'-') term)*
    ///   term   := power (('*'|'/'|'%') power)*      ('%' after a number = percent)
    ///   power  := unary ('^' power)?
    ///   unary  := ('-'|'+') unary | postfix
    ///   postfix:= primary ('!')?
    ///   primary:= number | const | func '(' expr ')' | '(' expr ')'
    struct Parser {
        static let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) },
            "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
            "asin": { Foundation.asin($0) }, "acos": { Foundation.acos($0) }, "atan": { Foundation.atan($0) },
            "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) }, "log2": { Foundation.log2($0) },
            "exp": { Foundation.exp($0) }, "round": { $0.rounded() }, "floor": { Foundation.floor($0) },
            "ceil": { Foundation.ceil($0) },
        ]
        let chars: [Character]
        var i = 0

        init(_ s: String) {
            chars = Array(s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "**", with: "^"))
        }

        mutating func parse() -> Double? {
            guard let v = expr() else { return nil }
            skip()
            return i == chars.count ? v : nil
        }

        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek() {
                if c == "*" || c == "/" {
                    i += 1
                    guard let r = power() else { return nil }
                    if c == "/" && r == 0 { return nil }
                    v = c == "*" ? v * r : v / r
                } else if c == "%" {
                    i += 1
                    // "50 % 7" is modulo; "20%" (end, or followed by an operator) is percent.
                    let save = i
                    if let n = peek(), n.isNumber || n == "(" || n == "." {
                        guard let r = power(), r != 0 else { return nil }
                        v = v.truncatingRemainder(dividingBy: r)
                    } else {
                        i = save
                        v = v / 100
                    }
                } else if c == "(" || c.isLetter {
                    // implicit multiplication: 2(3+4), 2pi
                    guard let r = power() else { return nil }
                    v *= r
                } else {
                    break
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return Foundation.pow(base, e)
            }
            return base
        }

        mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "+" {
                i += 1
                guard let v = unary() else { return nil }
                return c == "-" ? -v : v
            }
            return postfix()
        }

        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while peek() == "!" {
                i += 1
                guard v >= 0, v <= 170, v == v.rounded() else { return nil }
                var r = 1.0
                var k = 2.0
                while k <= v { r *= k; k += 1 }
                v = r
            }
            return v
        }

        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," || chars[i] == "_" {
                    if chars[i] != "," && chars[i] != "_" { s.append(chars[i]) }
                    i += 1
                }
                // scientific notation 1e3
                if i < chars.count, chars[i] == "e" || chars[i] == "E",
                   i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" {
                    s.append("e"); i += 1
                    if chars[i] == "-" { s.append("-"); i += 1 }
                    while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
                }
                return Double(s)
            }
            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber { name.append(chars[i]); i += 1 }
                let lower = name.lowercased()
                if lower == "pi" || name == "π" { return Double.pi }
                if lower == "e" { return M_E }
                if lower == "tau" { return 2 * Double.pi }
                guard let f = Parser.functions[lower], peek() == "(" else { return nil }
                i += 1
                guard let arg = expr(), peek() == ")" else { return nil }
                i += 1
                return f(arg)
            }
            if c == "π" { i += 1; return Double.pi }
            return nil
        }
    }
}

/// Offline unit conversion between units of the same dimension.
public enum UnitConverter {
    struct UnitDef {
        let symbol: String     // shown in results
        let dimension: String
        let factor: Double     // to the dimension's base unit
        let offset: Double     // for temperature: base = value * factor + offset
    }

    static let units: [String: UnitDef] = {
        var u: [String: UnitDef] = [:]
        func add(_ names: [String], _ sym: String, _ dim: String, _ f: Double, _ off: Double = 0) {
            for n in names { u[n] = UnitDef(symbol: sym, dimension: dim, factor: f, offset: off) }
        }
        // length (m)
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], "mm", "length", 0.001)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], "cm", "length", 0.01)
        add(["m", "meter", "meters", "metre", "metres"], "m", "length", 1)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], "km", "length", 1000)
        add(["in", "inch", "inches", "\""], "in", "length", 0.0254)
        add(["ft", "foot", "feet", "'"], "ft", "length", 0.3048)
        add(["yd", "yard", "yards"], "yd", "length", 0.9144)
        add(["mi", "mile", "miles"], "mi", "length", 1609.344)
        add(["nmi", "nauticalmile", "nauticalmiles"], "nmi", "length", 1852)
        // mass (kg)
        add(["mg", "milligram", "milligrams"], "mg", "mass", 1e-6)
        add(["g", "gram", "grams"], "g", "mass", 0.001)
        add(["kg", "kilo", "kilos", "kilogram", "kilograms"], "kg", "mass", 1)
        add(["t", "tonne", "tonnes"], "t", "mass", 1000)
        add(["oz", "ounce", "ounces"], "oz", "mass", 0.028349523125)
        add(["lb", "lbs", "pound", "pounds"], "lb", "mass", 0.45359237)
        add(["st", "stone", "stones"], "st", "mass", 6.35029318)
        // volume (L)
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], "ml", "volume", 0.001)
        add(["cl", "centiliter", "centilitre"], "cl", "volume", 0.01)
        add(["l", "liter", "liters", "litre", "litres"], "L", "volume", 1)
        add(["tsp", "teaspoon", "teaspoons"], "tsp", "volume", 0.00492892159375)
        add(["tbsp", "tablespoon", "tablespoons"], "tbsp", "volume", 0.01478676478125)
        add(["floz", "fluidounce", "fluidounces"], "fl oz", "volume", 0.0295735295625)
        add(["cup", "cups"], "cup", "volume", 0.2365882365)
        add(["pt", "pint", "pints"], "pt", "volume", 0.473176473)
        add(["ukpt", "ukpint", "ukpints"], "UK pt", "volume", 0.56826125)
        add(["qt", "quart", "quarts"], "qt", "volume", 0.946352946)
        add(["gal", "gallon", "gallons"], "gal", "volume", 3.785411784)
        add(["ukgal", "ukgallon", "ukgallons"], "UK gal", "volume", 4.54609)
        // temperature (K)
        add(["c", "°c", "celsius", "degc"], "°C", "temperature", 1, 273.15)
        add(["f", "°f", "fahrenheit", "degf"], "°F", "temperature", 5.0 / 9.0, 273.15 - 32 * 5.0 / 9.0)
        add(["k", "kelvin"], "K", "temperature", 1, 0)
        // data (bytes; SI multiples like Finder)
        add(["b", "byte", "bytes"], "B", "data", 1)
        add(["kb", "kilobyte", "kilobytes"], "KB", "data", 1e3)
        add(["mb", "megabyte", "megabytes"], "MB", "data", 1e6)
        add(["gb", "gigabyte", "gigabytes"], "GB", "data", 1e9)
        add(["tb", "terabyte", "terabytes"], "TB", "data", 1e12)
        add(["kib", "kibibyte"], "KiB", "data", 1024)
        add(["mib", "mebibyte"], "MiB", "data", 1_048_576)
        add(["gib", "gibibyte"], "GiB", "data", 1_073_741_824)
        add(["tib", "tebibyte"], "TiB", "data", 1_099_511_627_776)
        // time (s)
        add(["ms", "millisecond", "milliseconds"], "ms", "time", 0.001)
        add(["s", "sec", "secs", "second", "seconds"], "s", "time", 1)
        add(["min", "mins", "minute", "minutes"], "min", "time", 60)
        add(["h", "hr", "hrs", "hour", "hours"], "h", "time", 3600)
        add(["d", "day", "days"], "d", "time", 86400)
        add(["wk", "week", "weeks"], "wk", "time", 604800)
        add(["yr", "year", "years"], "yr", "time", 31_557_600)
        // speed (m/s)
        add(["m/s", "mps"], "m/s", "speed", 1)
        add(["km/h", "kmh", "kph"], "km/h", "speed", 1000.0 / 3600.0)
        add(["mph"], "mph", "speed", 1609.344 / 3600.0)
        add(["kn", "knot", "knots"], "kn", "speed", 1852.0 / 3600.0)
        // area (m²)
        add(["m2", "sqm", "m²"], "m²", "area", 1)
        add(["km2", "sqkm", "km²"], "km²", "area", 1e6)
        add(["ft2", "sqft", "ft²"], "ft²", "area", 0.09290304)
        add(["acre", "acres"], "acre", "area", 4046.8564224)
        add(["ha", "hectare", "hectares"], "ha", "area", 10000)
        return u
    }()

    /// "10 km to mi" / "10km in miles" / "72 f as c" / "3*4 ft to m".
    public static func convert(_ text: String) -> CalcResult? {
        let lower = text.lowercased()
        let separators = [" to ", " in ", " as ", " into ", " → ", " -> "]
        guard let sep = separators.first(where: { lower.contains($0) }),
              let r = lower.range(of: sep, options: .backwards) else { return nil }
        let lhs = String(lower[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let target = String(lower[r.upperBound...]).replacingOccurrences(of: " ", with: "")
        guard let to = units[target] ?? units[singular(target)] else { return nil }
        // Split the left side into a numeric expression and a trailing unit.
        guard let (amountText, unitText) = splitAmount(lhs),
              let from = units[unitText] ?? units[singular(unitText)],
              from.dimension == to.dimension else { return nil }
        let amount: Double
        if let d = Double(amountText) {
            amount = d
        } else {
            var p = Calculator.Parser(amountText)
            guard let v = p.parse() else { return nil }
            amount = v
        }
        let base = amount * from.factor + from.offset
        let out = (base - to.offset) / to.factor
        guard out.isFinite else { return nil }
        return .conversion(value: out, unit: to.symbol, from: amount, fromUnit: from.symbol)
    }

    private static func singular(_ s: String) -> String { s.hasSuffix("s") ? String(s.dropLast()) : s }

    private static func splitAmount(_ lhs: String) -> (String, String)? {
        // Longest unit suffix that matches a known unit.
        let compact = lhs.trimmingCharacters(in: .whitespaces)
        var best: (String, String)?
        for (name, _) in units where compact.hasSuffix(name) {
            let amount = String(compact.dropLast(name.count)).trimmingCharacters(in: .whitespaces)
            guard !amount.isEmpty, let last = amount.last, last.isNumber || last == ")" || last == "." else { continue }
            if best == nil || name.count > best!.1.count { best = (amount, name) }
        }
        return best
    }
}
