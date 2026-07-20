package bus.imu;

import com.tinkerforge.BrickIMUV2;
import java.util.ArrayDeque;
import java.util.Deque;

/** Bounded, thread-safe bridge from Tinkerforge callbacks to MATLAB. */
public final class ImuAllDataBuffer implements BrickIMUV2.AllDataListener {
    public static final int DEFAULT_CAPACITY = 256;

    public static final class Snapshot {
        private final BrickIMUV2.AllDataCallbackData data;
        private final long sequence;
        private final long timestampEpochMillis;
        private final long timestampNanos;

        Snapshot(BrickIMUV2.AllDataCallbackData data, long sequence,
                 long timestampEpochMillis, long timestampNanos) {
            this.data = data;
            this.sequence = sequence;
            this.timestampEpochMillis = timestampEpochMillis;
            this.timestampNanos = timestampNanos;
        }

        public BrickIMUV2.AllDataCallbackData getData() { return data; }
        public long getSequence() { return sequence; }
        public long getTimestampEpochMillis() { return timestampEpochMillis; }
        public long getTimestampNanos() { return timestampNanos; }
        public long getAgeNanos() {
            return Math.max(0L, System.nanoTime() - timestampNanos);
        }
    }

    private final int capacity;
    private final Deque<Snapshot> queue;
    private long receivedCount;
    private long droppedCount;
    private long lastSequence;

    public ImuAllDataBuffer() { this(DEFAULT_CAPACITY); }

    public ImuAllDataBuffer(int capacity) {
        if (capacity <= 0) {
            throw new IllegalArgumentException("capacity must be positive");
        }
        this.capacity = capacity;
        this.queue = new ArrayDeque<Snapshot>(capacity);
    }

    @Override
    public synchronized void allData(BrickIMUV2.AllDataCallbackData data) {
        receivedCount++;
        lastSequence++;
        if (queue.size() == capacity) {
            queue.removeFirst();
            droppedCount++;
        }
        queue.addLast(new Snapshot(data, lastSequence,
                System.currentTimeMillis(), System.nanoTime()));
    }

    /** Remove and return the oldest buffered sample. */
    public synchronized Snapshot pollOldest() { return queue.pollFirst(); }

    /** Return the newest sample and discard any older buffered samples. */
    public synchronized Snapshot pollLatest() {
        Snapshot latest = queue.pollLast();
        if (latest != null) {
            droppedCount += queue.size();
            queue.clear();
        }
        return latest;
    }

    /** Clear queued samples without resetting lifetime counters or sequence. */
    public synchronized void clear() {
        queue.clear();
    }

    public synchronized int size() { return queue.size(); }
    public int getCapacity() { return capacity; }
    public synchronized long getReceivedCount() { return receivedCount; }
    public synchronized long getDroppedCount() { return droppedCount; }
    public synchronized long getLastSequence() { return lastSequence; }
}
