package bus.imu;

/** Hardware-independent behavioral checks; callback payload may be null. */
public final class ImuAllDataBufferTest {
    public static void main(String[] args) {
        boundedAndDropped();
        latestDiscardsBacklog();
        fifoDrainIsSequential();
        clearStartsNewSession();
        longRunStaysBounded();
        System.out.println("ImuAllDataBufferTest passed");
    }

    private static void boundedAndDropped() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(3);
        offer(buffer, 5);
        check(buffer.size() == 3, "buffer exceeded maximum size");
        check(buffer.getDroppedCount() == 2, "overflow drop count is wrong");
    }

    private static void latestDiscardsBacklog() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 4);
        ImuAllDataBuffer.Snapshot latest = buffer.pollLatest();
        check(latest.getSequence() == 4, "pollLatest did not return newest sample");
        check(buffer.size() == 0, "pollLatest did not drain stale samples");
        check(buffer.getDroppedCount() == 3, "stale samples were not counted");
    }

    private static void fifoDrainIsSequential() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 4);
        for (long expected = 1; expected <= 4; expected++) {
            check(buffer.poll().getSequence() == expected, "FIFO order is broken");
        }
    }

    private static void clearStartsNewSession() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(8);
        offer(buffer, 3);
        buffer.clear();
        check(buffer.size() == 0 && buffer.getReceivedCount() == 0 &&
                buffer.getDroppedCount() == 0, "clear did not reset session");
        offer(buffer, 1);
        check(buffer.poll().getSequence() == 1, "sequence did not restart after clear");
    }

    private static void longRunStaysBounded() {
        ImuAllDataBuffer buffer = new ImuAllDataBuffer(32);
        offer(buffer, 1_000_000);
        check(buffer.size() == 32, "long simulation grew the queue");
        check(buffer.getReceivedCount() == 1_000_000, "received count is wrong");
    }

    private static void offer(ImuAllDataBuffer buffer, int count) {
        for (int index = 0; index < count; index++) buffer.allData(null);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
