package dev.nativelocation.tracker

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The body this builds is the only thing the server ever sees from a device,
 * and it is built where nothing can observe it — a foreground service, often
 * after the app itself is gone. So it is asserted here instead.
 */
class PayloadFormatTest {

    private fun entry(
        lat: Double = 9.0192,
        lng: Double = 38.7525,
        timestamp: Long = 1_788_256_800_000L, // 2026-09-01T10:00:00Z
        speed: Double? = 12.5,
        bearing: Double? = 90.0,
        accuracy: Double? = 5.0
    ) = NativeLocationBuffer.LocationEntry(
        id = 1L,
        pointId = "point-1",
        sessionId = "trip-1",
        lat = lat,
        lng = lng,
        timestamp = timestamp,
        speed = speed,
        bearing = bearing,
        accuracy = accuracy,
        altitude = null,
        deviceId = null,
        source = null,
        isMock = false,
        batteryLevel = null
    )

    private fun firstPoint(body: String, key: String = "points"): JSONObject =
        JSONObject(body).getJSONArray(key).getJSONObject(0)

    // ── The default, which every existing integration relies on ──

    @Test
    fun `an absent format sends exactly what the plugin always sent`() {
        val body = PayloadFormat.from(null).buildBody(listOf(entry()))
        val point = firstPoint(body)

        assertEquals(9.0192, point.getDouble("lat"), 0.0)
        assertEquals(38.7525, point.getDouble("lng"), 0.0)
        assertEquals(1_788_256_800_000L, point.getLong("timestamp"))
        assertEquals(90.0, point.getDouble("heading"), 0.0)
        assertEquals(5.0, point.getDouble("accuracy"), 0.0)
        // m/s converted to km/h, as it always was.
        assertEquals(45.0, point.getDouble("speed"), 0.0001)
    }

    @Test
    fun `an unreadable format falls back rather than losing the batch`() {
        // Stranding points on the device with nothing to say why is worse than
        // sending a shape the server may reject and log.
        val body = PayloadFormat.from("{ not json at all").buildBody(listOf(entry()))

        assertTrue(JSONObject(body).has("points"))
    }

    // ── Renames, formats and units ──

    @Test
    fun `a renamed field is the only one that moves`() {
        val format = PayloadFormat.from("""{"fields":{"timestamp":"recordedAt"}}""")
        val point = firstPoint(format.buildBody(listOf(entry())))

        assertTrue(point.has("recordedAt"))
        assertFalse(point.has("timestamp"))
        assertTrue(point.has("lat"))
        assertTrue(point.has("speed"))
    }

    @Test
    fun `iso 8601 is written in UTC whatever the device is set to`() {
        val format = PayloadFormat.from("""{"timeFormat":"iso8601_utc"}""")
        val point = firstPoint(format.buildBody(listOf(entry())))

        assertEquals("2026-09-01T10:00:00.000Z", point.getString("timestamp"))
    }

    @Test
    fun `epoch seconds drops the milliseconds`() {
        val format = PayloadFormat.from("""{"timeFormat":"epoch_seconds"}""")
        val point = firstPoint(format.buildBody(listOf(entry())))

        assertEquals(1_788_256_800L, point.getLong("timestamp"))
    }

    @Test
    fun `metres per second sends what the platform reported`() {
        val format = PayloadFormat.from("""{"speedUnit":"mps"}""")
        val point = firstPoint(format.buildBody(listOf(entry(speed = 12.5))))

        assertEquals(12.5, point.getDouble("speed"), 0.0001)
    }

    // ── Envelope ──

    @Test
    fun `the root key can be renamed`() {
        val format = PayloadFormat.from("""{"rootKey":"fixes"}""")
        val body = format.buildBody(listOf(entry()))

        assertTrue(JSONObject(body).has("fixes"))
    }

    @Test
    fun `a null root key posts a bare array as the whole body`() {
        val format = PayloadFormat.from("""{"rootKey":null}""")
        val body = format.buildBody(listOf(entry(), entry()))

        assertEquals(2, JSONArray(body).length())
    }

    @Test
    fun `extras are merged into the root, not into each point`() {
        val format = PayloadFormat.from("""{"extras":{"deviceId":"device-1"}}""")
        val body = format.buildBody(listOf(entry()))

        assertEquals("device-1", JSONObject(body).getString("deviceId"))
        assertFalse(firstPoint(body).has("deviceId"))
    }

    // ── Absent values ──

    @Test
    fun `a field the platform did not report is left out`() {
        val body = PayloadFormat.from(null)
            .buildBody(listOf(entry(speed = null, bearing = null, accuracy = null)))
        val point = firstPoint(body)

        // Absent says "the phone did not know". A null may be read as zero at
        // the far end, which is a different and false claim.
        assertFalse(point.has("speed"))
        assertFalse(point.has("heading"))
        assertFalse(point.has("accuracy"))
        assertTrue(point.has("lat"))
    }

    @Test
    fun `omitNull off sends an explicit null instead`() {
        val format = PayloadFormat.from("""{"omitNull":false}""")
        val point = firstPoint(format.buildBody(listOf(entry(speed = null))))

        assertTrue(point.has("speed"))
        assertTrue(point.isNull("speed"))
    }

    // ── The shape ChiNet's dispatch endpoint actually wants ──

    @Test
    fun `the full ChiNet session format builds the expected body`() {
        val format = PayloadFormat.from(
            """
            {
              "rootKey": "points",
              "fields": {"timestamp": "recordedAt"},
              "timeFormat": "iso8601_utc",
              "speedUnit": "mps",
              "extras": {"deviceId": "device-1"},
              "omitNull": true
            }
            """.trimIndent()
        )

        val body = format.buildBody(listOf(entry()))
        val root = JSONObject(body)
        val point = root.getJSONArray("points").getJSONObject(0)

        assertEquals("device-1", root.getString("deviceId"))
        assertEquals("2026-09-01T10:00:00.000Z", point.getString("recordedAt"))
        assertEquals(12.5, point.getDouble("speed"), 0.0001)
        assertEquals(9.0192, point.getDouble("lat"), 0.0)
        assertFalse(point.has("timestamp"))
    }
}
