
require-lib ../test-libs.sh

require-bin make-bcache
require-bin bcachectl
require-kernel-config BCACHE,BCACHE_DEBUG,CLOSURE_DEBUG

SYSFS=""
BDEV=""
CACHE=""
TIER=""
VOLUME=""
DISCARD=1
WRITEBACK=0
REPLACEMENT=lru

VIRTIO_BLKDEVS=0

DATA_REPLICAS=1
META_REPLICAS=1

#
# Bcache configuration
#
config-backing()
{
    add_bcache_devs BDEV $1
}

config-cache()
{
    add_bcache_devs CACHE $1
}

config-tier()
{
    add_bcache_devs TIER $1
}

config-volume()
{
    for size in $(echo $1 | tr ',' ' '); do
	if [ "$VOLUME" == "" ]; then
	    VOLUME=" "
	fi
	VOLUME+="$size"
    done
}

config-bucket-size()
{
    BUCKET_SIZE="$1"
}

config-block-size()
{
    BLOCK_SIZE="$1"
}

config-writeback()
{
    WRITEBACK=1
}

config-replacement()
{
    REPLACEMENT="$1"
}

config-data-replicas()
{
    DATA_REPLICAS="$1"
}

config-meta-replicas()
{
    META_REPLICAS="$1"
}

config-bcache-sysfs()
{
    if [ "$SYSFS" != "" ]; then
	SYSFS+="; "
    fi
    SYSFS+="for file in /sys/fs/bcache/*/$1; do echo $2 > \$file; done"
}

get_next_virtio()
{
    # Ugh...
    letter="$(printf "\x$(printf "%x" $((97 + $VIRTIO_BLKDEVS)))")"
    echo "/dev/vd$letter"
}

add_bcache_devs()
{
    for size in $(echo $2 | tr ',' ' '); do
	config-scratch-devs $size

	if [ "$(eval echo \$$1)" != "" ]; then
	    eval $1+='" "'
	fi
	dev="$(get_next_virtio)"
	VIRTIO_BLKDEVS=$(($VIRTIO_BLKDEVS + 1))
	eval $1+="$dev"
    done
}

make_bcache_flags()
{
    flags="--bucket $BUCKET_SIZE --block $BLOCK_SIZE --cache_replacement_policy=$REPLACEMENT"
    case "$DISCARD" in
	0) ;;
	1) flags+=" --discard" ;;
	*) echo "Bad discard: $DISCARD"; exit ;;
    esac
    case "$WRITEBACK" in
	0) ;;
	1) flags+=" --writeback" ;;
	*) echo "Bad writeback: $WRITEBACK"; exit ;;
    esac
    echo $flags
}

add_device() {
    DEVICES="$DEVICES /dev/bcache$DEVICE_COUNT"
    DEVICE_COUNT=$(($DEVICE_COUNT + 1))
}

#
# Registers all bcache devices.
#
# Upon successful completion, the DEVICES variable is set to a list of
# bcache block devices.
#
existing_bcache() {
    DEVICES=
    DEVICE_COUNT=0

    # Older kernel versions don't have /dev/bcache
    if [ -e /dev/bcacheXXX ]; then
	bcachectl register $CACHE $TIER $BDEV
    else
	for dev in $CACHE $TIER $BDEV; do
	    echo $dev > /sys/fs/bcache/register
	done
    fi

    # If we have one or more backing devices, then we get
    # one bcacheN per backing device.
    for device in $BDEV; do
	add_device
    done

    udevadm settle

    for device in $DEVICES; do
	wait_on_dev $device
    done

    cache_set_settings

    # Set up flash-only volumes.
    for volume in $VOLUME; do
	add_device
    done

    cached_dev_settings

    eval "$SYSFS"
}

#
# Registers all bcache devices after running make-bcache.
#
setup_bcache() {
    make_bcache_flags="$(make_bcache_flags)"
    make_bcache_flags+=" --wipe-bcache --cache $CACHE"
    make_bcache_flags+=" --data-replicas $DATA_REPLICAS"
    make_bcache_flags+=" --meta-replicas $META_REPLICAS"

    if [ "$TIER" != "" ]; then
	make_bcache_flags+=" --tier 1 $TIER"
    fi

    if [ "$BDEV" != "" ]; then
	make_bcache_flags+=" --bdev $BDEV"
    fi

    make-bcache $make_bcache_flags

    existing_bcache

    for size in $VOLUME; do
	for file in /sys/fs/bcache/*/flash_vol_create; do
	    echo $size > $file
	done
    done
}

stop_bcache()
{
    echo 1 > /sys/fs/bcache/reboot
}

cache_set_settings()
{
    for dir in $(ls -d /sys/fs/bcache/*-*-*); do
	true
	#echo 0 > $dir/synchronous
	echo panic > $dir/errors

	#echo 0 > $dir/journal_delay_ms
	#echo 1 > $dir/internal/key_merging_disabled
	#echo 1 > $dir/internal/btree_coalescing_disabled
	#echo 1 > $dir/internal/verify

	# This only exists if CONFIG_BCACHE_DEBUG is on
	if [ -f $dir/internal/expensive_debug_checks ]; then
	    echo 1 > $dir/internal/expensive_debug_checks
	fi

	echo 0 > $dir/congested_read_threshold_us
	echo 0 > $dir/congested_write_threshold_us

	echo 1 > $dir/internal/copy_gc_enabled
    done
}

cached_dev_settings()
{
    for dir in $(ls -d /sys/block/bcache*/bcache); do
	true
	#echo 128k    > $dir/readahead
	#echo 1	> $dir/writeback_delay
	#echo 0	> $dir/writeback_running
	#echo 0	> $dir/sequential_cutoff
	#echo 1	> $dir/verify
	#echo 1	> $dir/bypass_torture_test
    done
}
