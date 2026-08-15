Windows engine note
====================

The FVSsn file in this folder is a macOS executable and cannot run on
Windows. uFVS itself is cross-platform, but FVS projection requires a native
Windows FVS executable for the variant being modeled.

The official Windows FVS package is available from:
https://www.fs.usda.gov/fvs/software/complete.php

After installing it, uFVS checks the usual C:\FVS directory automatically. You
can also choose an FVS*.exe file on the Run page. If you want a portable copy,
place files such as FVSsn.exe in this folder; the Run page will detect them.

Without a Windows FVS executable, inventory import, validation, statistics,
keywords, and product-class setup still work. Projection and FVS-derived
volume tables do not.
