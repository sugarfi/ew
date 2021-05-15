# ew

ew is a yucky little package manager for installing yucky little packages. it doesn't do anything special,
i just wrote it for fun (and because all the cool kids are writing package managers amirite). it does have
a few notable features, tho:

- works entirely in a local directory, no root privileges needed for anything
- allows multiple operations in one command, like guix: `ew -u package -i package2`
- uses a simple package format and allows custom mirrors, so it's easy to host your own packages

## installation

download an ew binary from the releases page (if one is there) or clone this repository. to compile
from source, run:
```sh
crystal build -p --release src/ew.cr -o ew
```
then move the resulting `ew` binary somewhere in your `PATH`.

create a directory `~/.ew`, and in it create a file `mirrors`. in that file, write the url of each
mirror for packages you would like to add (they will be searched in the order you write them). if you
aren't sure, just write:
```
https://sugarfi.dev/ew
```

set up your shell config file or similar so that `~/.ew/bin` is in `PATH`. add `~/.ew/lib` to your `LD_LIBRARY_PATH`.

## usage

ew has a very simple syntax for commands. all commands are flags. when a command flag is given, all arguments or
options until the next command flag are taken to be arguments or options for that command. the valid commands are:

- `-h`: show a help message.
- `-q`: query a package and print information about it.
- `-i`: install a package.
- `-u`: uninstall a package.

for example, in the below command:
```
ew -i package1 -C -v -u package2 -u package3 -i package4 -v
```
the operations performed are, in order:

- `-i package1 -C -v`
- `-u package2`
- `-u package3`
- `-i package4 -v`

## available options

each command can take several options:

- `-q`
    * `-v`, `--verbose`: prints extra output.
    * `-V`, `--version`: the version of the package to use.
    * `-A`, `--arch`: the architecture to use.
- `-i PACKAGE`
    * `-v`, `--verbose`: prints extra output.
    * `-C`, `--copy`: don't build the package from source, only copy existing files.
    * `-V`, `--version`: the version of the package to use.
    * `-A`, `--arch`: the architecture to use.
- `-u PACKAGE`
    * `-v`, `--verbose`: prints extra output.

## creating your own package

if you have a web server, you can host your own repository of ew packages. creating a package is relatively simple.
in this example, we will walk through creating a simple 'hello' package.

### setting up the folders

first we need to create a folder for each architecture we want to have in our repository. for example, we might create
a folder `x86_64`, `aarch64`, etc. supported architectures are:

- `x86_64`
- `x86`
- `arm`
- `aarch64`

we'll use `x86_64` for now:
```sh
mkdir x86_64
cd x86_64
```

now we need a folder for our package. the name of this folder will be used as the name of the package.
```sh
mkdir hello
cd hello
```

now we need to figure out what version we want our package to be. ew does not enforce any versioning
scheme; we will use semver in this example. we need to first create a folder for this version of our
package:
```sh
mkdir 1.0.0
```
now we need to create an `info.toml` file, to tell ew the latest version of our package. if a user
doesn't specify the version they want to install, this value will be used. create a new file `info.toml`
and in it write:
```toml
version = "1.0.0"
```

now we can actually set up our package. `cd` into the `1.0.0` directory you just created. and create a file
`package.toml`. in it, write:
```
author = "you <email@domain.tld>"
license = "wtfpl"

[dependencies]

[install.build]
script = "build.sh"
[install.copy]
bin = "bin"
lib = "lib"
```
if you have any dependencies, add them in the format `package = "version:arch"`.

for convenience,
create a new directory `package`. in that, we'll put our code. create a file `main.c` and in it write:
```c
#include <stdio.h>

int main(int argc, char *argv[]) {
    if (argc >= 2) {
        printf("Hello %s!\n", argv[1]);
    } else {
        puts("Hello world!");
    }
}
```
now we need to create a build script. create a file `build.sh` with the contents:
```sh
#!/usr/bin/env bash

gcc -o bin/hello main.c
```
then `chmod +x build.sh` to make it executable.

at this point, all that's left is to compress our package. however, if we want to make our package 'copy-installable',
we'll need a few extra steps. before we look at that, it's important to understand how ew installs a package:
once it has downloaded and extracted your package, by default it will run the build script, specified in the toml
`[install.build] script`. then it looks at `[install.copy]`. it will take the (relative) path specified by `bin` and copy
non-recursively all files in it to `~/.ew/bin`. it will then do the same with `lib` and `~/.ew/lib`. if the user specifies
that the package is to be 'copy-installed' (using the `-C` flag), the process is the same, but the build script is not run;
files are simply copied directly over. this can be useful if the user doesn't want to build all packages from source.
we could use something like:
```sh
gcc -static -o package/bin/hello main.c
```
this requires the user to have the same version of glibc as you, however, so generally a non-copy-installable package is better.

ok, so now we have our package set up. all that's left is to compress it. `cd` back to the `1.0.0` directory and run
```
tar -c package.tar . -C package
gzip package.tar
```
to create `package.tar.gz`. that's it! assuming this file is hosted on a web server or similar, you can add the base url of the
root directory of your repository (the one where you created the `x86_64` directory) to your local ew mirrors file, and then run
`ew -i hello` to install your package!

## bugs

there are probably a lot of bugs. if you find one, open an issue and i'll fix it, or fork it and pr a patch yourself.

## license

this code is licensed under the [do whatever the fuck you want public license](https://wtfpl.net).
