# Lujo
Interpreted programming language based on a subset of Lox.

This language was implemented in Zig and is based on the book [Crafting Interpreters](https://craftinginterpreters.com/).

# Building
To build this project do the following steps in order:

1. Install [Zig compiler](https://ziglang.org/). This code was made specifically for version `0.11.0`, so it may not work in newer versions.
2. Clone this repository.
3. Execute the following command in a shell: `zig build`

The executable will be generated in `zig-out/bin` directory.

# Examples
There are some examples of very small programs in Lujo contained in `examples/` directory.

To execute an example use the following command, where *script* is the name of the file:
```bash
zig-out/bin/lujo script
```

## Print
The file `examples/print.lujo` shows the print statement and string concatenation.

```javascript
// Basic print statement testing

print "Hello, world!";
var name = "Fernando";
var surname = "Flores";
print "Your name is " + name + " " + surname;

var     operation       =       2*2+2-(10-20);
print "The result is: ";
print operation;

print 2 + 3*10; // Should print 32
```

Program output:
```
$ zig-out/bin/lujo examples/print.lujo
Hello, world!
Your name is Fernando Flores
The result is:
16
32
```

## Fibonacci number
The file `examples/fib.lujo` is an example where it shows most of the features of Lujo in a single script. It shows function declaration, recursive function calls, variables, conditionals and loops. It should print the 10th fibonacci number twice (55).

```javascript
fun fibRecursive(n) {
  if (n < 2) return n;
  return fibRecursive(n - 1) + fibRecursive(n - 2); 
}

fun fibIterative(n) {
    var a = 0;
    var b = 1;
    var c;

    if (n == 0) return a;

    for (var i = 2; i <= n; i = i + 1) {
        c = a + b;
        a = b;
        b = c;
    }

    return b;
}

// Should print 55 twice
print fibRecursive(10);
print fibIterative(10);
```

Program output:
```bash
$ zig-out/bin/lujo examples/fib.lujo
55
55
```

## TODO
- Add garbage collector
- Fix closures not working as intended in some circumstances

## Features that will not be implemented
- Classes
