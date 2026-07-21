package bus.imu;

import com.tinkerforge.BrickIMUV2;
import java.util.ArrayDeque;
import java.util.Deque;

/** Bounded, thread-safe bridge from Tinkerforge callbacks to MATLAB. */
public final class ImuAllDataBuffer implements BrickIMUV2.AllDataListener {
    public static final int DEFAULT_CAPACITY = 256;

    public static final class Snapshot {
        private final BrickIMUV2.AllDataCallbackData data;
        private final long sessionId;
        private final long sequence;
        private final long timestampEpochMillis;
        private final long timestampNanos;

        Snapshot(BrickIMUV2.AllDataCallbackData data, long sessionId, long sequence,
                 long timestampEpochMillis, long timestampNanos) {
            this.data = data;
            this.sessionId = sessionId;
            this.sequence = sequence;
            this.timestampEpochMillis = timestampEpochMillis;
            this.timestampNanos = timestampNanos;
        }

        public BrickIMUV2.AllDataCallbackData getData() { return data; }
        public long getSessionId() { return sessionId; }
        public long getSequence() { return sequence; }
        public long getTimestampMillis() { return timestampEpochMillis; }
        public long getTimestampEpochMillis() { return timestampEpochMillis; }
        public long getTimestampNanos() { return timestampNanos; }
        public long getAgeNanos() {
            return Math.max(0L, System.nanoTime() - timestampNanos);
        }
    }

    private final int capacity;
    private final Deque<Snapshot> queue;
    private long sessionId;
    private long receivedCount;
    private long overflowDroppedCount;
    private long coalescedCount;
    private long staleSessionDropCount;
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
        addSnapshot(data, sessionId);
    }

    void allDataForSession(BrickIMUV2.AllDataCallbackData data, long callbackSessionId) {
        synchronized (this) {
            addSnapshot(data, callbackSessionId);
        }
    }

    private void addSnapshot(BrickIMUV2.AllDataCallbackData data, long callbackSessionId) {
        if (callbackSessionId != sessionId) {
            staleSessionDropCount++;
            return;
        }
        receivedCount++;
        lastSequence++;
        if (queue.size() == capacity) {
            queue.removeFirst();
            overflowDroppedCount++;
        }
        queue.addLast(new Snapshot(data, sessionId, lastSequence,
                System.currentTimeMillis(), System.nanoTime()));
    }

    /** Remove and return the oldest buffered sample. */
    public synchronized Snapshot pollOldest() { return queue.pollFirst(); }

    /** Return the newest sample and discard any older buffered samples. */
    public synchronized Snapshot pollLatest() {
        Snapshot latest = queue.pollLast();
        if (latest != null) {
            coalescedCount += queue.size();
            queue.clear();
        }
        return latest;
    }

    /** Clear queued samples without resetting lifetime counters or sequence. */
    public synchronized void clear() {
        queue.clear();
    }

    /** Atomically start an isolated stream session. */
    public synchronized long beginSession() {
        sessionId++;
        queue.clear();
        receivedCount = 0;
        overflowDroppedCount = 0;
        coalescedCount = 0;
        staleSessionDropCount = 0;
        lastSequence = 0;
        return sessionId;
    }

    public synchronized int size() { return queue.size(); }
    public int getCapacity() { return capacity; }
    public int getMaxSize() { return capacity; }
    public synchronized long getSessionId() { return sessionId; }
    public synchronized long getReceivedCount() { return receivedCount; }
    public synchronized long getOverflowDroppedCount() { return overflowDroppedCount; }
    public synchronized long getCoalescedCount() { return coalescedCount; }
    public synchronized long getStaleSessionDropCount() { return staleSessionDropCount; }
    public synchronized long getLastSequence() { return lastSequence; }
}
