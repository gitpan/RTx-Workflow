#!/usr/bin/env perl
# $File: //member/autrijus/RTx-Workflow/Makefile.PL $ $Author: autrijus $
# $Revision: #2 $ $Change: 7971 $ $DateTime: 2003/09/08 00:46:40 $

use 5.006;
use inc::Module::Install;

include_deps   ('Test::More', 5.006);
build_requires ('Test::More', 0);

warn << '.';
### PLEASE NOTE ##############################################

This is *PRE-ALPHA* code.  Using this module for anything
(except for learning purporses) is strongly discouraged.

##############################################################
.

# XXX - figure out how to install po/ and html/

WriteMakefile (
    AUTHOR	    => 'Autrijus Tang (autrijus@autrijus.org)',
    NAME	    => 'RTx::Workflow',
    ABSTRACT	    => 'RT Workflow Extension',
    VERSION_FROM    => 'lib/RTx/Workflow.pm',
);

