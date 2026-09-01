package dev.nativelocation.tracker

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Getting this wrong is expensive in both directions: too eager and a live trip
 * is thrown away over a server hiccup, too shy and a phone uploads to a dead
 * session until its battery goes.
 */
class TerminalResponseTest {

    @Test
    fun `nothing is terminal unless configured`() {
        // The behaviour before this existed, and what every integration that
        // has not opted in still gets.
        val none = TerminalResponse.from(null)

        assertTrue(none.isEmpty)
        assertFalse(none.matches(410, "gone"))
        assertFalse(none.matches(500, null))
    }

    @Test
    fun `a configured status is terminal`() {
        val terminal = TerminalResponse.from("""{"statuses":[409,410]}""")

        assertTrue(terminal.matches(410, null))
        assertTrue(terminal.matches(409, null))
    }

    @Test
    fun `a status not listed is left to retry`() {
        val terminal = TerminalResponse.from("""{"statuses":[409,410]}""")

        // A gateway having a bad minute, and a token that can still be
        // refreshed. Neither is permanent.
        assertFalse(terminal.matches(502, null))
        assertFalse(terminal.matches(401, null))
    }

    @Test
    fun `a message match is case-insensitive and matches a substring`() {
        val terminal = TerminalResponse.from("""{"messages":["unknown link"]}""")

        assertTrue(
            terminal.matches(401, """{"message":"Unknown link","statusCode":401}""")
        )
    }

    @Test
    fun `a message can make terminal a status that is not listed`() {
        // The reason this exists: 401 drives token refresh and cannot be made
        // terminal wholesale, but on an endpoint with no auth scheme a 401 is
        // as permanent as it gets.
        val terminal = TerminalResponse.from(
            """{"statuses":[410],"messages":["unknown link"]}"""
        )

        assertTrue(terminal.matches(401, "Unknown link"))
        // The same status without the marker is still refreshable.
        assertFalse(terminal.matches(401, "Token expired"))
    }

    @Test
    fun `a body that says nothing matches nothing`() {
        val terminal = TerminalResponse.from("""{"messages":["unknown link"]}""")

        assertFalse(terminal.matches(401, null))
        assertFalse(terminal.matches(401, ""))
    }

    @Test
    fun `hasMessages says whether reading the body could tell us anything`() {
        // Reading the error stream costs IO on every failed upload, so it is
        // skipped where no message is configured.
        assertFalse(TerminalResponse.from("""{"statuses":[410]}""").hasMessages)
        assertTrue(TerminalResponse.from("""{"messages":["gone"]}""").hasMessages)
    }

    @Test
    fun `an unreadable config keeps retrying rather than inventing a refusal`() {
        // Falling back the other way would throw away a live trip over a
        // malformed setting.
        val terminal = TerminalResponse.from("{ not json")

        assertTrue(terminal.isEmpty)
        assertFalse(terminal.matches(410, "gone"))
    }

    @Test
    fun `garbage entries are ignored rather than taken literally`() {
        val terminal = TerminalResponse.from(
            """{"statuses":[0,-1,410],"messages":["",""]}"""
        )

        assertTrue(terminal.matches(410, null))
        assertFalse(terminal.hasMessages)
        // A zero or negative status would otherwise sit in the set and match
        // nothing, which is harmless — but an empty message would match every
        // body ever sent.
        assertFalse(terminal.matches(200, "anything at all"))
    }
}
