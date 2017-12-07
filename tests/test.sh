#!/bin/bash

/usr/bin/expect -f test.expect &
/usr/bin/expect -f test1.expect &
/usr/bin/expect -f test2.expect &
/usr/bin/expect -f test3.expect &
/usr/bin/expect -f test4.expect &
/usr/bin/expect -f test5.expect &
/usr/bin/expect -f test6.expect &
/usr/bin/expect -f test7.expect &
/usr/bin/expect -f test8.expect &
/usr/bin/expect -f test9.expect &
wait
