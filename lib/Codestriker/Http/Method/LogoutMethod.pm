###############################################################################
# Codestriker: Copyright (c) 2001, 2002 David Sitsky.  All rights reserved.
# sits@users.sourceforge.net
#
# This program is free software; you can redistribute it and modify it under
# the terms of the GPL.

# Method for executing the logout action.
package Codestriker::Http::Method::LogoutMethod;

use strict;
use Codestriker::Http::Method;
use Codestriker::Action::Logout;

@Codestriker::Http::Method::LogoutMethod::ISA = ("Codestriker::Http::Method");

# Generate a URL for this method.
sub url {
    my ($self, %args) = @_;

    if ($self->{cgi_style}) {
        return $self->{url_prefix} . "?action=logout";
    } else {
        return $self->{url_prefix} . "/logout";
    }
}

sub extract_parameters {
    my ($self, $http_input) = @_;

    my $action = $http_input->{query}->param('action');
    my $path_info = $http_input->{query}->path_info();
    if ($self->{cgi_style} && defined $action && $action eq "logout") {
        return 1;
    } elsif ($path_info =~ m{^/logout}) {
        $self->_extract_nice_parameters($http_input);
        return 1;
    } else {
        return 0;
    }
}

sub requires_authentication {
    return 1;
}

sub execute {
    my ($self, $http_input, $http_output) = @_;

    Codestriker::Action::Logout->process($http_input, $http_output);
}

1;