### Airflow tarball prep scripts

These scripts are used to build airflow tarball used by rpm/deb packages built by Acceldata ODP.

Airflow so far (till JAN 2025 ) used tarballs hosted at [common tarballs](https://mirror.odp.acceldata.dev/ODP/PY-UTILS/) for all releases till 3.3.6.2-1 and 3.2.3.4-2/3. which was not the best decision cause if a cve is to be fixed, or a new feature there is no documentation or steps to recreate that tarball. this is my attempt to make airflow tarballs easy and clean way to build.

with these changes i intend to make airflow code bit more manageable and trackable (Maybe one day we can build directly from source code rather than pip packages)

[This file shows pip packages in old tarball (the hosted one at PY-UTILS)](./notes/old-tarball-piplist.txt)

[This file shows pip packages in new tarball (built using these scripts)](./notes/new-tarball-piplist.txt)

