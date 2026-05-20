import Testing
@testable import AISwitcher

struct L10nTests {
    @Test
    func turkishModeUsesTurkishAutomationStrings() {
        #expect(L10n.resolve("Otomasyon güveni", "Automation confidence", storedLanguage: "tr", systemLanguageCode: "en") == "Otomasyon güveni")
        #expect(L10n.resolve("İlgi gereken hesaplar", "Accounts needing attention", storedLanguage: "tr", systemLanguageCode: "en") == "İlgi gereken hesaplar")
        #expect(L10n.resolve("Auth sorunu", "Stale", storedLanguage: "tr", systemLanguageCode: "en") == "Auth sorunu")
        #expect(L10n.resolve("Son doğrulama", "Last verified", storedLanguage: "tr", systemLanguageCode: "en") == "Son doğrulama")
        #expect(L10n.resolve("Sağlıklı", "Healthy", storedLanguage: "tr", systemLanguageCode: "en") == "Sağlıklı")
        #expect(L10n.resolve("Dikkat", "Attention", storedLanguage: "tr", systemLanguageCode: "en") == "Dikkat")
        #expect(L10n.resolve("Kritik", "Critical", storedLanguage: "tr", systemLanguageCode: "en") == "Kritik")
        #expect(L10n.resolve("Yeniden başlatma fallback", "Fallback restart", storedLanguage: "tr", systemLanguageCode: "en") == "Yeniden başlatma fallback")
        #expect(L10n.resolve("Manuel zorla geçiş", "Manual override", storedLanguage: "tr", systemLanguageCode: "en") == "Manuel zorla geçiş")
        #expect(L10n.resolve("Ertelendi", "Deferred", storedLanguage: "tr", systemLanguageCode: "en") == "Ertelendi")
        #expect(L10n.resolve("Belirsiz", "Inconclusive", storedLanguage: "tr", systemLanguageCode: "en") == "Belirsiz")
        #expect(L10n.resolve("Otomasyon dikkat istiyor", "Automation needs attention", storedLanguage: "tr", systemLanguageCode: "en") == "Otomasyon dikkat istiyor")
        #expect(L10n.resolve("Otomasyon acil dikkat istiyor", "Automation needs immediate attention", storedLanguage: "tr", systemLanguageCode: "en") == "Otomasyon acil dikkat istiyor")
    }

    @Test
    func systemModeUsesSystemLanguageCode() {
        #expect(L10n.resolve("Sıfırla", "Reset", storedLanguage: "system", systemLanguageCode: "tr") == "Sıfırla")
        #expect(L10n.resolve("Sıfırla", "Reset", storedLanguage: "system", systemLanguageCode: "en") == "Reset")
    }
}
