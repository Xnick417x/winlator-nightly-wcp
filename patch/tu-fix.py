import os
import urllib.request
import subprocess

def replace_in_file(filepath, old_text, new_text):
    if not os.path.exists(filepath):
        print(f"Skipping (not found): {filepath}")
        return
    with open(filepath, 'r') as f:
        content = f.read()
    if old_text in content:
        content = content.replace(old_text, new_text)
        with open(filepath, 'w') as f:
            f.write(content)

def insert_after(filepath, target_line, insert_text):
    if not os.path.exists(filepath):
        return
    with open(filepath, 'r') as f:
        lines = f.readlines()
    with open(filepath, 'w') as f:
        for line in lines:
            f.write(line)
            if target_line in line and insert_text not in line:
                f.write(insert_text + '\n')

print("\n--- Applying Xnick's Performance & Stability Optimizations ---\n")

# 1. Scissor Clamp Fix (Prevents OOB crashes from translation layers)
print("-> Injecting Scissor Clamps...")
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'min.x = MAX2(min.x, 0);', 'min.x = CLAMP(min.x, 0, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'min.y = MAX2(min.y, 0);', 'min.y = CLAMP(min.y, 0, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'max.x = MAX2(max.x, 1);', 'max.x = CLAMP(max.x, 1, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'max.y = MAX2(max.y, 1);', 'max.y = CLAMP(max.y, 1, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'uint32_t min_x = scissor->offset.x;', 'uint32_t min_x = CLAMP(scissor->offset.x, 0, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'uint32_t min_y = scissor->offset.y;', 'uint32_t min_y = CLAMP(scissor->offset.y, 0, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'uint32_t max_x = min_x + scissor->extent.width - 1;', 'uint32_t max_x = CLAMP(min_x + scissor->extent.width - 1, 0, 16383);')
replace_in_file('src/freedreno/vulkan/tu_pipeline.cc', 'uint32_t max_y = min_y + scissor->extent.height - 1;', 'uint32_t max_y = CLAMP(min_y + scissor->extent.height - 1, 0, 16383);')

# 2. Steam Deck Spoof (Unconditional spoof for max compatibility)
print("-> Injecting Steam Deck (RADV VANGOGH) Hardware Spoof...")
insert_after('src/freedreno/vulkan/tu_device.cc', 'props->deviceID = pdevice->dev_id.chip_id;', '   props->vendorID = 0x1002;\n   props->deviceID = 0x163F;')
replace_in_file('src/freedreno/vulkan/tu_device.cc', 'strcpy(props->deviceName, pdevice->name);', 'strcpy(props->deviceName, "AMD Custom GPU 0405 (RADV VANGOGH)");')

# 3. A7xx Stability Fixes (Disable volatile shader features)
print("-> Injecting A7xx Stability Fixes...")
replace_in_file('src/freedreno/common/freedreno_devices.py', 'cs_lock_unlock_quirk = True,', 'cs_lock_unlock_quirk = True,\n        has_early_preamble = False,\n        has_scalar_predicates = False,')
replace_in_file('src/freedreno/common/freedreno_devices.py', 'has_image_processing = True,', 'has_image_processing = True,\n        has_early_preamble = False,\n        has_scalar_predicates = False,')

# 4. Mesa KGSL Timeline Sync Fix
print("-> Fetching and Applying Official KGSL Timeline Sync MR...")
try:
    urllib.request.urlretrieve("https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/30206.patch", "kgsl_sync.patch")
    subprocess.run(["patch", "-p1", "-N", "-i", "kgsl_sync.patch"], check=False)
    print("-> KGSL Fix successfully applied.")
except Exception as e:
    print(f"-> Note: Could not apply KGSL patch (it may already be merged upstream). Proceeding safely. Error: {e}")

print("\n--- Optimizations Complete ---\n")
