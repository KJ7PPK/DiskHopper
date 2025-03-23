# DiskHopper 🐇💽  
A Fast, Safe Disk Partition Migration Tool for Linux

DiskHopper is a robust, interactive Bash script designed to safely migrate data between disk partitions on Linux systems. It verifies every transfer before deleting source files, cleans up after itself, and provides clear feedback throughout the process. Whether you're shuffling media libraries or prepping disks for offsite storage, DiskHopper makes the job fast and painless.

## 🚀 Features
✅ Interactive partition selection (sources & destinations)  
✅ Displays SMART health, connection type (SATA/USB/NVMe), and usage  
✅ Auto-mounts unmounted partitions to `/mnt/migratetemp`  
✅ Uses `rsync` with verification before deleting source files  
✅ Cleans up temp mounts and warns if manual intervention is needed  
✅ Optional logging for audits or reviews  
✅ Pure Bash—no extra dependencies besides standard Linux tools  

## 📦 What DiskHopper Isn't
❌ It doesn't clone full partitions block-by-block (file-level migration only)  
❌ It doesn't add redundancy or backup logic (this is for migration)  
❌ No automatic scheduling or concurrency—keep it manual and safe  

## 🛠️ Requirements
- bash
- rsync
- smartmontools (smartctl)
- lsblk (comes with util-linux)
- sudo (required to mount/unmount partitions)

## ⚙️ How It Works
1. Lists all partitions (excluding your OS disk) with SMART status and disk info.
2. Lets you select multiple sources and destinations interactively.
3. Auto-mounts partitions to temp folders if unmounted.
4. Copies files using rsync, verifies them, and deletes files from the source only after a successful transfer.
5. Cleans up temp mounts and warns you if something needs manual cleanup.
6. Optional logs save the session for reference.

## 📝 Usage Example
```bash
git clone https://github.com/yourusername/DiskHopper.git
cd DiskHopper
chmod +x DiskHopper.sh
./DiskHopper.sh
```

## 🔒 Safety Features
- No files are deleted from the source until they've been fully copied and verified.
- Identical files already present at the destination are skipped and safely removed from the source.
- Automatic cleanup of mounts and temporary directories, with warnings if manual cleanup is needed.

## ✨ Credits
Originally built for Chris' homelab migration.  
Refined and battle-tested by late nights, coffee, and head scratches.  
Free to use, tweak, share—just don't sue us.

## 🔗 License
MIT License. See [LICENSE](LICENSE).

## 🚀 Why "DiskHopper"?
Because it jumps files between disks faster than a rabbit in a carrot patch. 🥕🐇💨
# DiskHopper
# DiskHopper
# DiskHopper
# DiskHopper
