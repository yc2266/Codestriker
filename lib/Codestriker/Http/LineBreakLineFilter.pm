###############################################################################
# Codestriker: Copyright (c) 2001, 2002 David Sitsky.  All rights reserved.
# sits@users.sourceforge.net
#
# This program is free software; you can redistribute it and modify it under
# the terms of the GPL.

# Line filter for handling line-breaks.
# entities.

package Codestriker::Http::LineBreakLineFilter;

use strict;

use Codestriker::Http::LineFilter;

@Codestriker::Http::LineBreakLineFilter::ISA =
    ("Codestriker::Http::LineFilter");

# Take the linebreak mode as a parameter.
sub new {
    my ($type, $brmode) = @_;

    my $self = Codestriker::Http::LineFilter->new();
    $self->{brmode} = $brmode;

    return bless $self, $type;
}

# Convert the spaces appropriately for line-breaking.
sub _filter {
    my ($self, $text) = @_;
    
    if ($self->{brmode} == $Codestriker::LINE_BREAK_ASSIST_MODE) {
	$text =~ s/^(\s+)/my $sp='';for(my $i=0;$i<length($1);$i++){$sp.='&nbsp;'}$sp;/ge;
    }
    else {
	$text =~ s/ /&nbsp;/g;
    }

    return $text;
}

# Convert the spaces appropriately for line-breaking.
sub filter {
    my ($self, $delta) = @_;
    
    $delta->{diff_old_lines} = $self->_filter($delta->{diff_old_lines});
    $delta->{diff_new_lines} = $self->_filter($delta->{diff_new_lines});
}

1;
