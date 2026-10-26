### Airflow tarball prep scripts

These scripts are used to build airflow tarball used by rpm/deb packages built by Acceldata ODP.

Airflow so far (till JAN 2025 ) used tarballs hosted at [common tarballs](https://mirror.odp.acceldata.dev/ODP/PY-UTILS/) for all releases till 3.3.6.2-1 and 3.2.3.4-2/3. which was not the best decision cause if a cve is to be fixed, or a new feature there is no documentation or steps to recreate that tarball. this is my attempt to make airflow tarballs easy and clean way to build.

with these changes i intend to make airflow code bit more manageable and trackable (Maybe one day we can build directly from source code rather than pip packages)

[This file shows pip packages in old tarball (the hosted one at PY-UTILS)](./notes/old-tarball-piplist.txt)

[This file shows pip packages in new tarball (built using these scripts)](./notes/new-tarball-piplist.txt)

[This file shows pip packages for the Python 3.11 production environment](./notes/python311-production-piplist.txt)


---

## Build

Two ways to build: `./buildtarball.sh` pulls airflow from pip (fast, uses official packages), while `./buildtarball-from-source.sh` compiles from the local source code in parent directory. Source build is slower but lets you apply patches, bugfixes, CVE fixes, or backport features from newer airflow versions, just edit the code and rebuild.

### Python version

The ODP 3.3.6 line only ships `python3.11` and `python3.12` interpreters, so the tarball
must be built against one of those. The builders default to 3.12; set `ODP_PY_VERSION` to
pick the other one:

```bash
ODP_PY_VERSION=3.11 ./buildtarball.sh
```

`install_python.sh` rejects any other version up front rather than failing later in the
build when the interpreter package turns out not to exist in the distro repositories.
