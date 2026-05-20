import Foundation
import Testing
@testable import AISwitcher

struct BudgetAlertPolicyTests {
    @Test
    func returnsAlertWhenBudgetIsExceeded() {
        let now = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 12))!
        let result = BudgetAlertPolicy.shouldAlert(
            totalCost: 120,
            budgetLimit: 100,
            lastAlertDate: nil,
            now: now
        )

        #expect(result == true)
    }

    @Test
    func suppressesRepeatAlertOnSameDay() {
        let now = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 12))!
        let result = BudgetAlertPolicy.shouldAlert(
            totalCost: 120,
            budgetLimit: 100,
            lastAlertDate: now.addingTimeInterval(-3600),
            now: now
        )

        #expect(result == false)
    }
}
