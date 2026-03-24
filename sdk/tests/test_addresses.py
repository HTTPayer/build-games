"""Quick test to verify SDK address loading from broadcast file."""

from composed._addresses import BROADCAST_FILE, FUJI_ADDRESSES

print(f"Broadcast file: {BROADCAST_FILE}")
print(f"Broadcast file exists: {BROADCAST_FILE.exists()}")
print()
print("Loaded addresses:")
for key, value in FUJI_ADDRESSES.items():
    print(f"  {key}: {value}")
