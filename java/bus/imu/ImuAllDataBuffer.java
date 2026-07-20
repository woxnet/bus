package bus.imu;

import com.tinkerforge.BrickIMUV2;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;

/** Thread-safe bridge from Tinkerforge's Java listener to MATLAB polling. */
public final class ImuAllDataBuffer implements BrickIMUV2.AllDataListener {
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

    private final AtomicLong sequence = new AtomicLong(0);
    private final ConcurrentLinkedQueue<Snapshot> queue = new ConcurrentLinkedQueue<Snapshot>();

    @Override
    public void allData(BrickIMUV2.AllDataCallbackData data) {
        long next = sequence.incrementAndGet();
        queue.add(new Snapshot(data, next, System.currentTimeMillis()));
    }

    public Snapshot poll() { return queue.poll(); }
    public long getSequence() { return sequence.get(); }
}
