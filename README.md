pg_pgrade_conf
==============

Quick perl script intended to be used to transplant PostgreSQL server settings from one conf file or server to another.

Primarily intended for copying current settings in postgresql.conf into the default copy provided by a newer version to maintain information regarding new settings and defaults.  The script can also read via SQL and apply settings via ALTER SYSTEM if required.

To transplant settings from one file to another, e.g. for upgrading and keeping the default comments in the new version:

```bash
$ ./pg_upgrade_conf.pl -f ../old/postgresql.conf -F ../new/postgresql.conf
```

Also take into account values set by ALTER SYSTEM on old server:


```bash
$ ./pg_upgrade_conf.pl -f ../old/postgresql.conf -a ../old/postgresql.auto.conf -F ../new/postgresql.conf
```

Apply settings via ALTER SYSTEM

```bash
$ ./pg_upgrade_conf.pl -f ../old/postgresql.conf -a ../old/postgresql.auto.conf -C 'dbname=TEST host=localhost port=5432 user=postgres'
```

Read settings via SQL and apply to new postgresql.conf:


```bash
$ ./pg_upgrade_conf.pl -c 'dbname=TEST host=localhost port=5433 user=postgres' -F ../new/postgresql.conf
```

Read settings via SQL and apply settings via ALTER SYSTEM:
 
```bash
$ ./pg_upgrade_conf.pl -c 'dbname=TEST host=localhost port=5433 user=postgres' -C 'dbname=TEST host=localhost port=5432 user=postgres' 
```
