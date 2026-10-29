package com.dmusic.app.dmusic_app

class WidgetPlaybackLease(
    val processToken: String,
    val timeoutMs: Long = 30_000L,
) {
    var generation: Long = 0L
        private set

    var closed: Boolean = true
        private set

    fun attach(): Long {
        generation += 1L
        closed = false
        return generation
    }

    fun close(expectedGeneration: Long? = null): Boolean {
        if (expectedGeneration != null && expectedGeneration != generation) return false
        closed = true
        return true
    }

    fun accepts(expectedGeneration: Long): Boolean = !closed && expectedGeneration == generation

    fun isFreshPlaying(
        isPlaying: Boolean,
        ownerToken: String?,
        lastHeartbeatElapsedMs: Long,
        nowElapsedMs: Long,
    ): Boolean {
        if (!isPlaying || closed || ownerToken != processToken) return false
        if (lastHeartbeatElapsedMs < 0L || nowElapsedMs < lastHeartbeatElapsedMs) return false
        return nowElapsedMs - lastHeartbeatElapsedMs <= timeoutMs
    }
}
