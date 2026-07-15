#include "macos_system.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

int weaver_system_sample(uint32_t *ticks, size_t core_capacity, size_t *core_count,
                         uint64_t *used_bytes, uint64_t *total_bytes) {
    if (!ticks || !core_count || !used_bytes || !total_bytes) return -1;
    natural_t processor_count = 0;
    processor_info_array_t processor_info = NULL;
    mach_msg_type_number_t processor_info_count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                            &processor_count, &processor_info,
                            &processor_info_count) != KERN_SUCCESS) return -1;

    const size_t count = processor_count < core_capacity ? processor_count : core_capacity;
    const processor_cpu_load_info_t loads = (processor_cpu_load_info_t)processor_info;
    for (size_t core = 0; core < count; core++) {
        for (size_t state = 0; state < WEAVER_CPU_STATE_COUNT; state++) {
            ticks[core * WEAVER_CPU_STATE_COUNT + state] = loads[core].cpu_ticks[state];
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)processor_info,
                  processor_info_count * sizeof(integer_t));

    uint64_t total = 0;
    size_t total_size = sizeof(total);
    vm_statistics64_data_t statistics = {0};
    mach_msg_type_number_t statistics_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    if (sysctlbyname("hw.memsize", &total, &total_size, NULL, 0) != 0 || total == 0 ||
        host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&statistics, &statistics_count) != KERN_SUCCESS ||
        host_page_size(mach_host_self(), &page_size) != KERN_SUCCESS || page_size == 0) return -1;
    const uint64_t reclaimable_pages = statistics.free_count + statistics.inactive_count;
    const uint64_t reclaimable = reclaimable_pages > total / page_size
        ? total : reclaimable_pages * page_size;
    *core_count = count;
    *total_bytes = total;
    *used_bytes = total - reclaimable;
    return 0;
}

int weaver_process_sample(int32_t pid, uint64_t *physical_footprint,
                          uint64_t *cpu_time_ns, uint32_t *threads) {
    if (!physical_footprint || !cpu_time_ns || !threads) return -1;
    struct rusage_info_v4 usage;
    struct proc_taskinfo task;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return -1;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) return -1;
    *physical_footprint = usage.ri_phys_footprint;
    *cpu_time_ns = usage.ri_user_time + usage.ri_system_time;
    *threads = task.pti_threadnum < 0 ? 0 : (uint32_t)task.pti_threadnum;
    return 0;
}

int weaver_process_path(int32_t pid, char *path, size_t capacity) {
    if (!path || capacity == 0) return -1;
    return proc_pidpath(pid, path, (uint32_t)capacity);
}

int weaver_chmod_private(const char *path) {
    return path ? chmod(path, 0700) : -1;
}
