package com.dmusic.app.dmusic_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetPlaybackLeaseTest {
    @Test
    fun unattachedLeaseRejectsPlayback() {
        val lease = WidgetPlaybackLease("process-a")

        assertTrue(lease.closed)
        assertFalse(lease.accepts(lease.generation))
        assertFalse(lease.isFreshPlaying(true, "process-a", 100L, 100L))
    }

    @Test
    fun attachAcceptsOnlyItsCurrentGeneration() {
        val lease = WidgetPlaybackLease("process-a")
        val firstGeneration = lease.attach()

        assertFalse(lease.closed)
        assertTrue(lease.accepts(firstGeneration))
        val secondGeneration = lease.attach()
        assertTrue(secondGeneration > firstGeneration)
        assertFalse(lease.accepts(firstGeneration))
        assertTrue(lease.accepts(secondGeneration))
    }

    @Test
    fun closeRejectsLatePlaybackFromTheClosedGeneration() {
        val lease = WidgetPlaybackLease("process-a")
        val generation = lease.attach()

        assertTrue(lease.close(generation))
        assertTrue(lease.closed)
        assertFalse(lease.accepts(generation))
        assertFalse(lease.isFreshPlaying(true, "process-a", 100L, 101L))
    }

    @Test
    fun oldCloseCannotCloseANewAttachment() {
        val lease = WidgetPlaybackLease("process-a")
        val oldGeneration = lease.attach()
        val currentGeneration = lease.attach()

        assertFalse(lease.close(oldGeneration))
        assertTrue(lease.accepts(currentGeneration))
        assertTrue(lease.isFreshPlaying(true, "process-a", 100L, 101L))
    }

    @Test
    fun unconditionalCloseClosesCurrentAttachment() {
        val lease = WidgetPlaybackLease("process-a")
        val generation = lease.attach()

        assertTrue(lease.close())
        assertFalse(lease.accepts(generation))
    }

    @Test
    fun reattachRestoresPlaybackWithoutAcceptingOldCallbacks() {
        val lease = WidgetPlaybackLease("process-a")
        val oldGeneration = lease.attach()
        lease.close(oldGeneration)
        val newGeneration = lease.attach()

        assertFalse(lease.accepts(oldGeneration))
        assertTrue(lease.accepts(newGeneration))
        assertTrue(lease.isFreshPlaying(true, "process-a", 100L, 101L))
    }

    @Test
    fun persistedPlaybackFromAnotherProcessIsRejected() {
        val lease = WidgetPlaybackLease("new-process")
        lease.attach()

        assertFalse(lease.isFreshPlaying(true, "old-process", 100L, 101L))
        assertFalse(lease.isFreshPlaying(true, null, 100L, 101L))
        assertTrue(lease.isFreshPlaying(true, "new-process", 100L, 101L))
    }

    @Test
    fun pausedStateIsNeverFreshPlaying() {
        val lease = WidgetPlaybackLease("process-a")
        lease.attach()

        assertFalse(lease.isFreshPlaying(false, "process-a", 100L, 101L))
    }

    @Test
    fun heartbeatIsValidThroughTheDefaultTimeoutBoundary() {
        val lease = WidgetPlaybackLease("process-a")
        lease.attach()

        assertTrue(lease.isFreshPlaying(true, "process-a", 100L, 30_100L))
        assertFalse(lease.isFreshPlaying(true, "process-a", 100L, 30_101L))
    }

    @Test
    fun customTimeoutUsesElapsedHeartbeatAge() {
        val lease = WidgetPlaybackLease("process-a", timeoutMs = 500L)
        lease.attach()

        assertTrue(lease.isFreshPlaying(true, "process-a", 100L, 600L))
        assertFalse(lease.isFreshPlaying(true, "process-a", 100L, 601L))
    }

    @Test
    fun invalidOrReversedElapsedTimesAreRejected() {
        val lease = WidgetPlaybackLease("process-a")
        lease.attach()

        assertFalse(lease.isFreshPlaying(true, "process-a", -1L, 100L))
        assertFalse(lease.isFreshPlaying(true, "process-a", 0L, -1L))
        assertFalse(lease.isFreshPlaying(true, "process-a", 100L, 99L))
        assertFalse(lease.isFreshPlaying(true, "process-a", 0L, Long.MAX_VALUE))
        assertTrue(lease.isFreshPlaying(true, "process-a", 0L, 0L))
    }
}
