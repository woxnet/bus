package bus.imu;

/** Hardware-independent behavioral checks; callback payload may be null. */
public final class ImuAllDataBufferTest {
    public static void main(String[] args) {
        boundedAndDropped();
        latestDiscardsBacklog();
        fifoDrainIsSequential();
        clearPreservesLifetimeSequence();
        sessionsAreIsolated();
        lossReasonsAreSeparate();
        concurrentProducerConsumerStaysBounded();
        monotonicTimingIgnoresEpochAdjustment();
        longRunStaysBounded();
        System.out.println("ImuAllDataBufferTest passed");
    }

    private static void boundedAndDropped() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(3);
        offer(buffer, 5);
        check(buffer.size() == 3, "buffer exceeded maximum size");
        check(buffer.getCapacity() == 3, "capacity is wrong");
        check(buffer.getOverflowDroppedCount() == 2, "overflow drop count is wrong");
    }

    private static void latestDiscardsBacklog() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 4);
        ImuAllDataBuffer.Snapshot latest = buffer.pollLatest();
        check(latest.getSequence() == 4, "pollLatest did not return newest sample");
        check(buffer.size() == 0, "pollLatest did not drain stale samples");
        check(buffer.getCoalescedCount() == 3, "coalesced samples were not counted");
        check(buffer.getOverflowDroppedCount() == 0, "coalescing counted as overflow");
    }

    private static void fifoDrainIsSequential() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 4);
        for (long expected = 1; expected <= 4; expected++) {
            check(buffer.pollOldest().getSequence() == expected, "FIFO order is broken");
        }
    }

    private static void clearPreservesLifetimeSequence() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 3);
        buffer.clear();
        check(buffer.size() == 0, "clear did not empty queue");
        check(buffer.getReceivedCount() == 3 && buffer.getOverflowDroppedCount() == 0,
                "clear reset lifetime counters");
        offer(buffer, 1);
        ImuAllDataBuffer.Snapshot snapshot = buffer.pollOldest();
        check(snapshot.getSequence() == 4, "sequence restarted after clear");
        check(snapshot.getTimestampEpochMillis() > 0, "epoch timestamp is missing");
        check(snapshot.getTimestampNanos() > 0 && snapshot.getAgeNanos() >= 0,
                "monotonic timestamp is invalid");
    }

    private static void sessionsAreIsolated() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        long oldSession = buffer.beginSession();
        offer(buffer, 2);
        long currentSession = buffer.beginSession();
        check(currentSession == oldSession + 1, "session ID did not advance");
        buffer.allDataForSession(null, oldSession);
        check(buffer.size() == 0 && buffer.getStaleSessionDropCount() == 1,
                "stale callback was not rejected");
        offer(buffer, 1);
        ImuAllDataBuffer.Snapshot sample = buffer.pollOldest();
        check(sample.getSessionId() == currentSession, "snapshot has wrong session");
        check(sample.getSequence() == 1, "new session sequence did not restart at one");
    }

    private static void lossReasonsAreSeparate() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(2);
        long session = buffer.beginSession();
        offer(buffer, 3);
        buffer.pollLatest();
        buffer.allDataForSession(null, session - 1);
        check(buffer.getOverflowDroppedCount() == 1, "overflow counter is wrong");
        check(buffer.getCoalescedCount() == 1, "coalesced counter is wrong");
        check(buffer.getStaleSessionDropCount() == 1, "stale counter is wrong");
    }

    private static void concurrentProducerConsumerStaysBounded() {
        final ImuAllDataBuffer buffer = new ImuAllDataBuffer(64);
        buffer.beginSession();
        Thread producer = new Thread(new Runnable() {
            public void run() { offer(buffer, 200_000); }
        });
        Thread consumer = new Thread(new Runnable() {
            public void run() {
                while (producer.isAlive()) buffer.pollOldest();
            }
        });
        producer.start();
        consumer.start();
        try {
            producer.join();
            consumer.join();
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new AssertionError("concurrency test interrupted");
        }
        check(buffer.size() <= buffer.getCapacity(), "concurrent access exceeded capacity");
        check(buffer.getReceivedCount() == 200_000, "concurrent received count is wrong");
    }

    private static void monotonicTimingIgnoresEpochAdjustment() {
        ImuAllDataBuffer.Snapshot first = new ImuAllDataBuffer.Snapshot(
                null, 1, 1, 2_000, 1_000_000_000L);
        ImuAllDataBuffer.Snapshot second = new ImuAllDataBuffer.Snapshot(
                null, 1, 2, 1_000, 1_020_000_000L);
        check(second.getTimestampMillis() < first.getTimestampMillis(),
                "test does not emulate backward wall-clock adjustment");
        check(second.getTimestampNanos() - first.getTimestampNanos() == 20_000_000L,
                "monotonic interval was affected by epoch time");
    }

    private static void longRunStaysBounded() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(32);
        offer(buffer, 1_000_000);
        check(buffer.size() == 32, "long simulation grew the queue");
        check(buffer.getReceivedCount() == 1_000_000, "received count is wrong");
        check(buffer.getOverflowDroppedCount() == 999_968, "long-run drop count is wrong");
    }

    private static void offer(ImuAllDataBuffer buffer, int count) {
        for (int index = 0; index < count; index++) buffer.allData(null);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
