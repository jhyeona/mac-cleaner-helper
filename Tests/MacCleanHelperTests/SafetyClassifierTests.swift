import XCTest
@testable import MacCleanHelper

final class SafetyClassifierTests: XCTestCase {
    func testStartupDiskTopLevelItemsAreProtected() {
        let classifier = SafetyClassifier()

        XCTAssertEqual(classifier.classify(path: "/Applications").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "/Users").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "/.file").risk, .avoid)
    }

    func testPersonalAndCredentialRootsAreProtected() {
        let classifier = SafetyClassifier()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(classifier.classify(path: "\(home)/Documents").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "\(home)/Library").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "\(home)/.ssh").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "\(home)/Library/Preferences").risk, .avoid)
    }
    private let classifier = SafetyClassifier()
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testSystemPathsAreNeverSuggestedForDeletion() {
        XCTAssertEqual(classifier.classify(path: "/System/Library/Fonts").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "/Library/Application Support").risk, .avoid)
    }

    func testUserCacheCanBeSuggestedWithImpactExplanation() {
        let result = classifier.classify(path: "\(home)/Library/Caches/com.example.app")

        XCTAssertEqual(result.risk, .safe)
        XCTAssertFalse(result.impact.isEmpty)
    }

    func testPersonalDownloadsRequireReview() {
        XCTAssertEqual(
            classifier.classify(path: "\(home)/Downloads/important.zip").risk,
            .review
        )
    }

    func testPersonalMessagesAreProtected() {
        XCTAssertEqual(classifier.classify(path: "\(home)/Library/Messages/chat.db").risk, .avoid)
    }

    func testPrefixCollisionDoesNotMatchProtectedRoot() {
        XCTAssertEqual(classifier.classify(path: "/SystemBackup/file.dat").risk, .review)
    }

    func testDatabaseAndKeychainFilesAreProtected() {
        XCTAssertEqual(classifier.classify(path: "\(home)/project/state.sqlite").risk, .avoid)
        XCTAssertEqual(classifier.classify(path: "\(home)/Library/Keychains/login.keychain-db").risk, .avoid)
    }

    func testNormalProjectBelowDocumentsIsNotMistakenForPersonalOriginal() {
        XCTAssertEqual(classifier.classify(path: "\(home)/Documents/sample-project").risk, .review)
    }
}
