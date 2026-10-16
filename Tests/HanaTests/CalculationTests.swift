import Foundation
import Testing
@testable import Hana

struct CalculationTests {
    private let locale = Locale(identifier: "en_US")

    @Test func basicArithmeticAppearsAsAnAnswer() throws {
        let answer = try #require(Calculation.answer(for: "12 * 4 + 3", locale: locale))
        #expect(answer.state == .value)
        #expect(answer.title == "51")
        #expect(answer.subtitle == "12 * 4 + 3")
        #expect(answer.copyableText == "51")
    }

    @Test(arguments: [
        ("12 *", Answer.State.incomplete, "…", "Keep typing"),
        ("(3 + 4", .incomplete, "…", "Keep typing"),
        ("12 * -", .incomplete, "…", "Keep typing"),
        ("(3 + 4 +", .incomplete, "…", "Keep typing"),
        ("sqrt", .incomplete, "…", "Keep typing"),
        ("5 / 0 +", .incomplete, "…", "Keep typing"),
        ("5 / 0", .divisionByZero, "Uh oh", "Can't divide by zero"),
        ("5 / (3 - 3)", .divisionByZero, "Uh oh", "Can't divide by zero"),
        ("3 + * 4", .invalid, "Not a valid calculation", "3 + * 4"),
        ("3 + *", .invalid, "Not a valid calculation", "3 + *"),
        ("1..2", .invalid, "Not a valid calculation", "1..2"),
        ("1 2 + 3", .invalid, "Not a valid calculation", "1 2 + 3"),
        ("3 + 4)", .invalid, "Not a valid calculation", "3 + 4)"),
        ("(3 + * 4", .invalid, "Not a valid calculation", "(3 + * 4"),
        ("3 + ()", .invalid, "Not a valid calculation", "3 + ()"),
        ("12 * )", .invalid, "Not a valid calculation", "12 * )"),
        ("5 / 0 + * 2", .invalid, "Not a valid calculation", "5 / 0 + * 2"),
        (" 3 + * 4 ", .invalid, "Not a valid calculation", " 3 + * 4 ")
    ])
    func calculationsWithoutAValueCarryTheirStateAndExactWording(
        text: String, state: Answer.State, title: String, subtitle: String
    ) throws {
        let answer = try #require(Calculation.answer(for: text, locale: locale))
        #expect(answer.state == state)
        #expect(answer.title == title)
        #expect(answer.subtitle == subtitle)
        #expect(answer.copyableText == nil)
    }
    @Test(arguments: [
        ("", false), ("2024", false), ("pi", false), ("e", false),
        ("rent 1200 / 3", false), ("tax 3x4", false), ("3 x pi", false),
        ("extra", false), ("sqrtish(4)", false), ("https://3/4", false),
        ("2024-10-16", true), ("12 *", true), ("5 / 0", true),
        ("3 + * 4", true), ("1..2", true), ("sqrt", true),
        ("SIN(pi)", true), ("2pi", true), ("2(3 + 4)", true),
        ("3x4", true), (".3 x .4", true), ("3 x 4", true), ("3×4", true),
        ("2^10", true), ("50%", true), ("1e-3 + 2", true)
    ])
    func recognizesOnlyTheCalculationLanguage(text: String, expected: Bool) {
        #expect(Calculation.recognizes(text, locale: locale) == expected)
        if !expected { #expect(Calculation.answer(for: text, locale: locale) == nil) }
    }
    @Test(arguments: [
        ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"),
        ("10 / (2 + 3)", "2"), ("-5 + 3", "-2"),
        ("2 * -3", "-6"), ("-(2 + 3)", "-5"),
        ("2024-10-16", "1,998"), ("0.1 + 0.2", "0.3"),
        ("10 / 4", "2.5")
    ])
    func evaluatesArithmeticWithExactDecimals(text: String, expected: String) {
        #expect(Calculation.answer(for: text, locale: locale)?.title == expected)
    }

    @Test(arguments: [
        ("123456789012345 + 0", "123,456,789,012,345", "123456789012345"),
        ("999999999999999.9 + 0", "1e15", "1e15"),
        ("1234567890123456 + 0", "1.2345679e15", "1.2345679e15"),
        ("1 / 3", "0.33333333", "0.33333333"),
        ("123456789 / 100", "1,234,567.9", "1234567.9"),
        ("1 / 100000000", "0.00000001", "0.00000001"),
        ("1 / 1000000000", "1e-9", "1e-9"),
        ("123456789012345678901 + 0", "1.2345679e20", "1.2345679e20"),
        ("-1234.5 + 0", "-1,234.5", "-1234.5"),
        ("0.0000000001 - 0.0000000001", "0", "0"),
        ("10 / 4", "2.5", "2.5")
    ])
    func formatsAnswersAndCopyableText(text: String, title: String, copy: String) throws {
        let answer = try #require(Calculation.answer(for: text, locale: locale))
        #expect(answer.title == title)
        #expect(answer.copyableText == copy)
    }

    @Test func typingAndDisplayFollowTheExplicitLocale() throws {
        let answer = try #require(Calculation.answer(for: "1.234,5 + 0,1", locale: Locale(identifier: "de_DE")))
        #expect(answer.title == "1.234,6")
        #expect(answer.copyableText == "1234,6")
    }

}
