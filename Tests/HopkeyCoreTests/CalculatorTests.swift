import XCTest
@testable import HopkeyCore

final class CalculatorTests: XCTestCase {
    func testBasicArithmetic() {
        XCTAssertEqual(Calculator.evaluate("2+2"), "4")
        XCTAssertEqual(Calculator.evaluate("10 - 3"), "7")
        XCTAssertEqual(Calculator.evaluate("6*7"), "42")
        XCTAssertEqual(Calculator.evaluate("20/4"), "5")
    }

    func testPrecedenceAndParens() {
        XCTAssertEqual(Calculator.evaluate("2+3*4"), "14")
        XCTAssertEqual(Calculator.evaluate("(2+3)*4"), "20")
        XCTAssertEqual(Calculator.evaluate("2*(3+(4-1))"), "12")
    }

    func testUnaryMinus() {
        XCTAssertEqual(Calculator.evaluate("-5+3"), "-2")
        XCTAssertEqual(Calculator.evaluate("3*-2"), "-6")
    }

    func testDecimalsAndModulo() {
        XCTAssertEqual(Calculator.evaluate("1.5+1.5"), "3")
        XCTAssertEqual(Calculator.evaluate("0.1+0.2"), "0.3")   // %.10g гасит хвост 0.30000000004
        XCTAssertEqual(Calculator.evaluate("10%3"), "1")
    }

    func testNotAnExpressionReturnsNil() {
        XCTAssertNil(Calculator.evaluate("safari"))       // буквы
        XCTAssertNil(Calculator.evaluate("5"))            // просто число, без оператора
        XCTAssertNil(Calculator.evaluate(""))
        XCTAssertNil(Calculator.evaluate("   "))
        XCTAssertNil(Calculator.evaluate("+"))            // нет цифр
    }

    func testMalformedReturnsNilWithoutCrashing() {
        XCTAssertNil(Calculator.evaluate("2++"))
        XCTAssertNil(Calculator.evaluate("(2+3"))         // незакрытая скобка
        XCTAssertNil(Calculator.evaluate("2+3)"))         // лишняя скобка
        XCTAssertNil(Calculator.evaluate("*5"))
    }

    func testDivisionByZeroReturnsNil() {
        XCTAssertNil(Calculator.evaluate("5/0"))          // inf → не число, не показываем
    }
}
