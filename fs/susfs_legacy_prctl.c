// SPDX-License-Identifier: GPL-2.0
#include <linux/cred.h>
#include <linux/errno.h>
#include <linux/sched.h>
#include <linux/susfs.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>


/*
 * ReSukiSU compatibility for the v1.5.9 NON-GKI SUSFS implementation.
 *
 * Newer ReSukiSU expects a few helpers introduced after the legacy prctl ABI.
 * Keep their semantics separate from the legacy app-process flag:
 * - PROC_UMOUNTED is backed by its own thread_info bit in susfs_def.h.
 * - v1.5.9 has no deferred loop-path repair work, so extra_works is a
 *   deliberately empty, correctly initialized work item.
 * - v1.5.9 userspace explicitly configures /sdcard roots, so no kernel
 *   fsnotify monitor is required.
 */
extern void try_umount(const char *mnt, int flags);

void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)
{
    (void)check_mnt;
    (void)uid;
    try_umount(mnt, flags);
}

static void susfs_legacy_extra_workfn(struct work_struct *work)
{
    (void)work;
}
DECLARE_WORK(susfs_extra_works, susfs_legacy_extra_workfn);

void susfs_start_sdcard_monitor_fn(void)
{
    /* Legacy v1.5.9: userspace issues SET_*_ROOT_PATH after unlock. */
}

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
static bool susfs_hide_sus_mnts_for_all_procs;

bool susfs_should_hide_mount(void)
{
    if (current_uid().val == 0)
        return false;
    if (READ_ONCE(susfs_hide_sus_mnts_for_all_procs))
        return true;
    return susfs_is_current_non_root_user_app_proc();
}
#else
bool susfs_should_hide_mount(void)
{
    return false;
}
#endif

#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern void susfs_run_try_umount_for_current_mnt_ns(void);

/* 4.19 patch calls the historical name from namespace.c. */
void susfs_try_umount_all(uid_t uid)
{
    susfs_try_umount(uid);
}
#endif

static void susfs_reply_result(unsigned long arg5, int result)
{
    if (arg5)
        copy_to_user((void __user *)arg5, &result, sizeof(result));
}

static bool susfs_legacy_known_cmd(unsigned long cmd)
{
    switch (cmd) {
    case CMD_SUSFS_ADD_SUS_PATH:
    case CMD_SUSFS_SET_ANDROID_DATA_ROOT_PATH:
    case CMD_SUSFS_SET_SDCARD_ROOT_PATH:
    case CMD_SUSFS_ADD_SUS_MOUNT:
    case CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS:
    case CMD_SUSFS_UMOUNT_FOR_ZYGOTE_ISO_SERVICE:
    case CMD_SUSFS_ADD_SUS_KSTAT:
    case CMD_SUSFS_UPDATE_SUS_KSTAT:
    case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
    case CMD_SUSFS_ADD_TRY_UMOUNT:
    case CMD_SUSFS_SET_UNAME:
    case CMD_SUSFS_ENABLE_LOG:
    case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
    case CMD_SUSFS_ADD_OPEN_REDIRECT:
    case CMD_SUSFS_RUN_UMOUNT_FOR_CURRENT_MNT_NS:
    case CMD_SUSFS_SHOW_VERSION:
    case CMD_SUSFS_SHOW_ENABLED_FEATURES:
    case CMD_SUSFS_SHOW_VARIANT:
    case CMD_SUSFS_SHOW_SUS_SU_WORKING_MODE:
    case CMD_SUSFS_IS_SUS_SU_READY:
    case CMD_SUSFS_SUS_SU:
        return true;
    default:
        return false;
    }
}

bool susfs_handle_legacy_prctl(int option, unsigned long cmd,
                               unsigned long arg3, unsigned long arg4,
                               unsigned long arg5, long *syscall_ret)
{
    int result = -EOPNOTSUPP;

    if (option != SUSFS_LEGACY_PRCTL_OPTION || !susfs_legacy_known_cmd(cmd))
        return false;

    /* Historical SUSFS command channel is root-only. */
    if (current_uid().val != 0)
        return false;

    switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
    case CMD_SUSFS_ADD_SUS_PATH:
        result = susfs_add_sus_path((struct st_susfs_sus_path __user *)arg3);
        break;
    case CMD_SUSFS_SET_ANDROID_DATA_ROOT_PATH:
    case CMD_SUSFS_SET_SDCARD_ROOT_PATH:
        result = susfs_set_i_state_on_external_dir((char __user *)arg3, cmd);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
    case CMD_SUSFS_ADD_SUS_MOUNT:
        result = susfs_add_sus_mount((struct st_susfs_sus_mount __user *)arg3);
        break;
    case CMD_SUSFS_HIDE_SUS_MNTS_FOR_ALL_PROCS:
        if (arg3 > 1) {
            result = -EINVAL;
        } else {
            WRITE_ONCE(susfs_hide_sus_mnts_for_all_procs, !!arg3);
            result = 0;
        }
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
    case CMD_SUSFS_ADD_SUS_KSTAT:
    case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
        result = susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
        break;
    case CMD_SUSFS_UPDATE_SUS_KSTAT:
        result = susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
    case CMD_SUSFS_ADD_TRY_UMOUNT:
        result = susfs_add_try_umount((struct st_susfs_try_umount __user *)arg3);
        break;
    case CMD_SUSFS_RUN_UMOUNT_FOR_CURRENT_MNT_NS:
        susfs_run_try_umount_for_current_mnt_ns();
        result = 0;
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
    case CMD_SUSFS_SET_UNAME:
        result = susfs_set_uname((struct st_susfs_uname __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
    case CMD_SUSFS_ENABLE_LOG:
        if (arg3 > 1) {
            result = -EINVAL;
        } else {
            susfs_set_log(!!arg3);
            result = 0;
        }
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
        result = susfs_set_cmdline_or_bootconfig((char __user *)arg3);
        break;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
    case CMD_SUSFS_ADD_OPEN_REDIRECT:
        result = susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg3);
        break;
#endif
    case CMD_SUSFS_SHOW_VERSION:
        result = copy_to_user((void __user *)arg3, SUSFS_VERSION,
                              sizeof(SUSFS_VERSION)) ? -EFAULT : 0;
        break;
    case CMD_SUSFS_SHOW_ENABLED_FEATURES:
        if (!arg4)
            result = -EINVAL;
        else
            result = susfs_get_enabled_features((char __user *)arg3, arg4);
        break;
    case CMD_SUSFS_SHOW_VARIANT:
        result = copy_to_user((void __user *)arg3, SUSFS_VARIANT,
                              sizeof(SUSFS_VARIANT)) ? -EFAULT : 0;
        break;

    /* The current 4.19 NON-GKI implementation has no SUS_SU or zygote-ISO
     * control hook wired to ReSukiSU. Be explicit instead of pretending. */
    case CMD_SUSFS_UMOUNT_FOR_ZYGOTE_ISO_SERVICE:
    case CMD_SUSFS_SHOW_SUS_SU_WORKING_MODE:
    case CMD_SUSFS_IS_SUS_SU_READY:
    case CMD_SUSFS_SUS_SU:
        result = -EOPNOTSUPP;
        break;
    default:
        break;
    }

    susfs_reply_result(arg5, result);
    *syscall_ret = 0;
    return true;
}
