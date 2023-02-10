# fast-apt-mirror.sh <a href="https://github.com/vegardit/fast-apt-mirror.sh/" title="GitHub Repo"><img height="30" src="https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/github.svg?sanitize=true"></a>

[![Build](https://github.com/vegardit/fast-apt-mirror.sh/actions/workflows/build.yml/badge.svg)](https://github.com/vegardit/fast-apt-mirror.sh/actions/workflows/build.yml)
[![Build Status](https://vegardit.semaphoreci.com/badges/fast-apt-mirror.sh/branches/v1.svg?key=895f50fb-c056-41dc-9580-d7cdfac023df "Semaphore CI")](https://vegardit.semaphoreci.com/projects/fast-apt-mirror.sh)
[![License](https://img.shields.io/github/license/vegardit/fast-apt-mirror.sh.svg?label=license)](#license)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.0%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)


**Feedback and high-quality pull requests are highly welcome!**

1. [What is it?](#what-is-it)
1. [Installation](#installation)
1. [Usage](#usage)
   1. [`current` command](#current-command)
   1. [`find` command](#find-command)
   1. [`set` command](#set-command)
1. [Alternatives](#alternatives)
1. [License](#license)


## <a name="what-is-it"></a>What is it?

**fast-apt-mirror.sh** is a self-contained Bash script that helps you easily and quickly determine and configure a fast APT mirror
on [Debian](https://www.debian.org/), [Ubuntu](https://ubuntu.com/), [Pop!_OS](https://pop.system76.com/) systems.

It was born out of the ongoing stability [issues](https://github.com/actions/runner-images/issues?q=is%3Aissue+azure.archive.ubuntu.com) with the `azure.archive.ubuntu.com` Ubuntu
mirror pre-configured in Github Actions runners.


## <a name="installation"></a>Installation

For example:
```bash
# install pre-reqs: bash, curl and HTTPS transport support for apt
$ sudo apt-get install -y bash curl apt-transport-https ca-certificates

# install fast-apt-mirror.sh under /usr/local/bin/ to make it automatically available via $PATH
$ sudo curl https://raw.githubusercontent.com/vegardit/fast-apt-mirror.sh/v1/fast-apt-mirror.sh -o /usr/local/bin/fast-apt-mirror.sh
$ sudo chmod 755 /usr/local/bin/fast-apt-mirror.sh
```


## <a name="usage"></a>Usage

Available sub commands:
```yml
fast-apt-mirror.sh COMMAND

Available commands:
 current - Prints the currently configured APT mirror.
 find    - Finds and prints the URL of a fast APT mirror and optionally applies it using the 'fast-apt-mirror.sh set' command.
 set     - Configures the given APT mirror in /etc/apt/sources.list and runs 'sudo apt-get update'.
```

### <a name="current-command"></a>The `current` sub command

Determines the currently effective APT mirror.
```sh
$ fast-apt-mirror.sh current
Current mirror: http://artfiles.org/ubuntu
```

Capture the current mirror URL in a variable:
```sh
$ current_mirror=$(fast-apt-mirror.sh current)
$ echo $current_mirror
http://artfiles.org/ubuntu
```

### <a name="find-command"></a>The `find` sub command

Determines and prints the URL of a fast APT mirror and optionally activates it.

To perform the connectivity and speed tests, the `curl` command must be installed.

Usage:
```yml
fast-apt-mirror.sh find [OPTION]...

Options:
     --apply            - Replaces the current APT mirror in /etc/apt/sources.list with a fast mirror and runs 'sudo apt-get update'
     --exclude-current  - If specified, don't include the current APT mirror in the speed tests.
 -p, --parallel N       - Number of parallel speed tests. May result in incorrect results because of competing connections but finds a suitable mirror faster.
     --healthchecks N   - Number of mirrors from the Ubuntu/Debian mirror lists to check for availability and up-to-dateness - default is 20
     --speedtests N     - Maximum number of healthy mirrors to test for speed - default is 5
     --sample-size KB   - Number of kilobytes to download during the speed from each mirror - default is 200KB
     --sample-time SECS - Maximum number of seconds within the sample download from a mirror must finish - default is 3
 -v, --verbose          - More output. Specify multiple times to increase verbosity.
```

Finding a fast mirror:
```sh
$ fast-apt-mirror.sh find

Current mirror: http://artfiles.org/ubuntu/
Randomly selecting 20 mirrors...done
Checking sync status of 20 mirrors....................done
 -> 20 mirrors are reachable and up-to-date
Speed testing 5 of the available 20 mirrors (sample download size: 200KB).....done
 -> https://mirror.netzwerge.de/ubuntu/ (1470 KB/s) determined as fastest mirror within 4 seconds
```

Capturing the determined mirror URL in a variable
```sh
$ fast_mirror=$(fast-apt-mirror.sh find)
$ echo $fast_mirror
https://mirror.netzwerge.de/ubuntu/
```

Finding and activating a fast mirror:
```sh
$ fast-apt-mirror.sh find --apply

Current mirror: http://azure.archive.ubuntu.com/ubuntu/
Randomly selecting 20 mirrors...done
Checking sync status of 20 mirrors....................done
 -> 20 mirrors are reachable and up-to-date
Speed testing 5 of the available 20 mirrors (sample download size: 200KB).....done
 -> https://ubuntu.mirror.shastacoe.net/ubuntu/ (2409 KB/s) determined as fastest mirror within 6 seconds
Current mirror: http://azure.archive.ubuntu.com/ubuntu/
Creating backup /etc/apt/sources.list.bak.20230207_211544
Changing mirror from [http://azure.archive.ubuntu.com/ubuntu/] to [https://ubuntu.mirror.shastacoe.net/ubuntu/]...
Hit:1 https://packages.microsoft.com/ubuntu/20.04/prod focal InRelease
Get:2 https://ubuntu.mirror.shastacoe.net/ubuntu focal InRelease [265 kB]
....
Fetched 27.1 MB in 5s (5915 kB/s)
Reading package lists... Done
```

### <a name="set-command"></a>The `set` sub command

Finds and prints the URL of a fast APT mirror and optionally applies it using the `fast-apt-mirror.sh set` command.

Usage:
```yml
fast-apt-mirror.sh set MIRROR_URL

Parameters:
  MIRROR_URL - the APT mirror URL to configure.
```

Example:
```sh
$ fast-apt-mirror.sh set https://mirrors.xtom.com/ubuntu/

Current mirror: http://azure.archive.ubuntu.com/ubuntu/
Creating backup /etc/apt/sources.list.bak.20230207_211544
Changing mirror from [http://azure.archive.ubuntu.com/ubuntu/] to [https://mirrors.xtom.com/ubuntu/]...
Hit:1 https://packages.microsoft.com/ubuntu/20.04/prod focal InRelease
Get:2 https://ubuntu.mirror.shastacoe.net/ubuntu focal InRelease [265 kB]....
...
Fetched 26.9 MB in 5s (4211 kB/s)
Reading package lists... Done
```


## <a name="alternatives"></a>Alternatives

Here is a list of possible alternative which didn't work for us for one reason or another:
- **apt-select** https://github.com/jblakeman/apt-select (Python based, last commit 11/2019)
- **apt-smart** https://github.com/martin68/apt-smart (Python based, last commit 05/2020)
- **apt-spy** https://github.com/scanepa/apt-spy (C based, last commit 01/2012)
- **apt-spy2** https://github.com/lagged/apt-spy2 (Ruby based, last commit 05/2020)
- **getfastmirror** https://github.com/hychen/getfastmirror (Python based, last commit 07/2010)
- **python-apt-mirror-updater** https://github.com/xolox/python-apt-mirror-updater (Python based, last commit 09/2021)
- **netselect-apt** https://github.com/apenwarr/netselect/blob/master/netselect-apt (Bash based, 10/2010, [Limitations](https://manpages.debian.org/bullseye/netselect-apt/netselect-apt.1.en.html#LIMITATIONS))


## <a name="license"></a>License

All files are released under the [Apache License 2.0](LICENSE.txt).

Individual files contain the following tag instead of the full license text:
```
SPDX-License-Identifier: Apache-2.0
```

This enables machine processing of license information based on the SPDX License Identifiers that are available here: https://spdx.org/licenses/.
