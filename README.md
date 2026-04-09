**🇬🇧 English** | [🇷🇺 Русский](README-RU.md)

> [!CAUTION]
> **THIS SCRIPT PERFORMS BACKUP AND RESTORE OF REMNAWAVE AND SHM PANELS — INCLUDING THEIR DIRECTORIES AND DATABASES. BACKUP AND RESTORE OF ANY OTHER SERVICES AND CONFIGURATIONS IS ENTIRELY THE USER'S RESPONSIBILITY. IT IS RECOMMENDED TO CAREFULLY FOLLOW THE INSTRUCTIONS DURING SCRIPT EXECUTION BEFORE RUNNING ANY COMMANDS.**

## Features:
- interactive menu
- manual and scheduled automatic backup creation
- independent backup/restore for Remnawave and SHM
- external PostgreSQL support (Remnawave)
- notifications directly to Telegram bot or group topic with attached backup
- script version update notifications
- backup size check before sending to TG and limit exceeded notification
- backup upload to Google Drive or S3 Storage (optional)
- configurable backup retention policy for server-side and S3 backups separately

## Main menu:

```
RW & SHM BACKUP & RESTORE
v3.3.1
[Remnawave ✓] [SHM ✓]

   1. Create backup
   2. Restore from backup

   3. Backup sources
   4. Auto-send
   5. Upload method
   6. Settings

   7. Update script
   8. Remove script

   0. Exit
```

## Installation (requires root):

```bash
curl -o ~/backup-restore.sh https://raw.githubusercontent.com/k0sha/rw-shm-backup-restore/main/backup-restore.sh && chmod +x ~/backup-restore.sh && ~/backup-restore.sh
```

## Commands:
- `rw-backup` — quick menu access from anywhere in the system
