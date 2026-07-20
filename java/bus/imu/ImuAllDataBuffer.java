package bus.imu;

import com.tinkerforge.BrickIMUV2;
import java.util.ArrayDeque;
import java.util.Deque;

/** Bounded, thread-safe bridge from Tinkerforge callbacks to MATLAB. */
public final class ImuAllDataBuffer implements BrickIMUV2.AllDataListener {
    public static final int DEFAULT_MAX_SIZE = 256;

    public static final class Snapshot {
        private final BrickIMUV2.AllDataCallbackData data;
        private final long sequence;
        private final long timestampMillis;

        Snapshot(BrickIMUV2.AllDataCallbackData data, long sequence, long timestampMillis) {
            this.data = data;
            this.sequence = sequence;
            this.timestampMillis = timestampMillis;
        }

        public BrickIMUV2.AllDataCallbackData getData() { return data; }
        public long getSequence() { return sequence; }
        public long getTimestampMillis() { return timestampMillis; }
    }

    private final int maxSize;
    private final Deque<Snapshot> queue;
    private long receivedCount;
    private long droppedCount;
    private long lastSequence;

    public ImuAllDataBuffer() { this(DEFAULT_MAX_SIZE); }

    public ImuAllDataBuffer(int maxSize) {
        if (maxSize <= 0) {
            throw new IllegalArgumentException("maxSize must be positive");
        }
        this.maxSize = maxSize;
        this.queue = new ArrayDeque<Snapshot>(maxSize);
    }

    @Override
    public synchronized void allData(BrickIMUV2.AllDataCallbackData data) {
        receivedCount++;
        lastSequence++;
        if (queue.size() == maxSize) {
            queue.removeFirst();
            droppedCount++;
        }
        queue.addLast(new Snapshot(data, lastSequence, System.currentTimeMillis()));
    }

    /** Remove and return the oldest buffered sample. */
    public synchronized Snapshot poll() { return queue.pollFirst(); }

    /** Return the newest sample and discard any older buffered samples. */
    public synchronized Snapshot pollLatest() {
        Snapshot latest = queue.pollLast();
        if (latest != null) {
            droppedCount += queue.size();
            queue.clear();
        }
        return latest;
    }

    /** Start a new stream session with an empty buffer and zeroed counters. */
    public synchronized void clear() {
        queue.clear();
        receivedCount = 0;
        droppedCount = 0;
        lastSequence = 0;
    }

    public synchronized int size() { return queue.size(); }
    public int getMaxSize() { return maxSize; }
    public synchronized long getReceivedCount() { return receivedCount; }
    public synchronized long getDroppedCount() { return droppedCount; }
    public synchronized long getLastSequence() { return lastSequence; }
}
