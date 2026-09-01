package dev.nativelocation.tracker

import android.util.Log
import org.json.JSONObject
import java.util.Locale

/**
 * What became of one upload attempt.
 *
 * Three, not two: "it did not work" and "it will never work" call for opposite
 * things — one keeps the batch for the next flush, the other stops the tracker.
 */
internal enum class UploadOutcome {
    SUCCESS,

    /** Try again later: a tunnel, a timeout, a server having a bad minute. */
    RETRY,

    /** Refused for good. Retrying it can only waste battery. */
    TERMINAL,
}

/**
 * Which upload responses mean "stop" rather than "try again later".
 *
 * Handed down from Dart as a JSON string (see `TerminalResponse` there) and
 * persisted, so a batch uploading long after the app was killed still knows
 * which refusals are permanent.
 *
 * Empty unless the host app configures it, which is the behaviour this plugin
 * had before: every non-2xx retried forever.
 */
internal class TerminalResponse private constructor(
    private val statuses: Set<Int>,
    /** Lower-cased once, at parse time — matching runs per response. */
    private val messages: List<String>
) {
    companion object {
        private const val TAG = "NLTTerminalResponse"

        private val NONE = TerminalResponse(emptySet(), emptyList())

        fun from(json: String?): TerminalResponse {
            if (json.isNullOrBlank()) return NONE

            return try {
                val root = JSONObject(json)

                val statuses = mutableSetOf<Int>()
                root.optJSONArray("statuses")?.let { array ->
                    for (i in 0 until array.length()) {
                        val status = array.optInt(i, -1)
                        if (status > 0) statuses.add(status)
                    }
                }

                val messages = mutableListOf<String>()
                root.optJSONArray("messages")?.let { array ->
                    for (i in 0 until array.length()) {
                        val message = array.optString(i, "")
                        if (message.isNotEmpty()) {
                            messages.add(message.lowercase(Locale.ROOT))
                        }
                    }
                }

                TerminalResponse(statuses, messages)
            } catch (e: Exception) {
                // Unreadable config must not invent a permanent refusal. Falling
                // back to "nothing is terminal" keeps retrying, which wastes
                // battery; the other way round throws away a live trip.
                Log.w(TAG, "Unreadable terminal-response config, ignoring it: ${e.message}")
                NONE
            }
        }
    }

    val isEmpty: Boolean get() = statuses.isEmpty() && messages.isEmpty()

    /** Whether reading the response body could tell us anything. */
    val hasMessages: Boolean get() = messages.isNotEmpty()

    /**
     * Whether this response will never succeed.
     *
     * [body] may be null — reading it is best-effort, and a status match does
     * not need it.
     */
    fun matches(status: Int, body: String?): Boolean {
        if (statuses.contains(status)) return true
        if (messages.isEmpty() || body.isNullOrEmpty()) return false

        val haystack = body.lowercase(Locale.ROOT)
        return messages.any { haystack.contains(it) }
    }

    /** For the error reported back to Dart. */
    fun describe(status: Int): String = "terminal_response_$status"
}
