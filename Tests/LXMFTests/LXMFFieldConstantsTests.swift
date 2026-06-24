import XCTest
@testable import LXMF

/// Tests for new LXMF field constants added in the 2026-05-24 LXMF.py update.
final class LXMFFieldConstantsTests: XCTestCase {

    // MARK: - New field IDs (Python: FIELD_REPLY_TO=0x30 … FIELD_CONTINUATION=0x42)

    func testFieldReplyTo() {
        XCTAssertEqual(Field.replyTo.rawValue, 0x30,
                       "Python: FIELD_REPLY_TO = 0x30")
    }

    func testFieldReplyQuote() {
        XCTAssertEqual(Field.replyQuote.rawValue, 0x31,
                       "Python: FIELD_REPLY_QUOTE = 0x31")
    }

    func testFieldReaction() {
        XCTAssertEqual(Field.reaction.rawValue, 0x40,
                       "Python: FIELD_REACTION = 0x40")
    }

    func testFieldComment() {
        XCTAssertEqual(Field.comment.rawValue, 0x41,
                       "Python: FIELD_COMMENT = 0x41")
    }

    func testFieldContinuation() {
        XCTAssertEqual(Field.continuation.rawValue, 0x42,
                       "Python: FIELD_CONTINUATION = 0x42")
    }

    // MARK: - Existing field still correct

    func testFieldThreadRawValue() {
        XCTAssertEqual(Field.thread.rawValue, 0x08,
                       "FIELD_THREAD must remain 0x08")
    }

    // MARK: - Reaction dict indices (Python: REACTION_TO=0x00, REACTION_CONTENT=0x01)

    func testReactionTo() {
        XCTAssertEqual(ReactionField.reactionTo.rawValue, 0x00,
                       "Python: REACTION_TO = 0x00")
    }

    func testReactionContent() {
        XCTAssertEqual(ReactionField.reactionContent.rawValue, 0x01,
                       "Python: REACTION_CONTENT = 0x01")
    }

    // MARK: - Comment dict indices (Python: COMMENT_FOR=0x00)

    func testCommentFor() {
        XCTAssertEqual(CommentField.commentFor.rawValue, 0x00,
                       "Python: COMMENT_FOR = 0x00")
    }

    // MARK: - Continuation dict indices (Python: CONTINUATION_OF=0x00)

    func testContinuationOf() {
        XCTAssertEqual(ContinuationField.continuationOf.rawValue, 0x00,
                       "Python: CONTINUATION_OF = 0x00")
    }

    // MARK: - Ordering sanity (reply before reaction, reaction before customType)

    func testReplyFieldsAreLessThanReactionFields() {
        XCTAssertLessThan(Field.replyTo.rawValue, Field.reaction.rawValue)
        XCTAssertLessThan(Field.replyQuote.rawValue, Field.reaction.rawValue)
    }

    func testNewFieldsAreLessThanCustomFields() {
        // Existing custom fields start at 0xFB
        XCTAssertLessThan(Field.continuation.rawValue, Field.customType.rawValue)
    }
}
