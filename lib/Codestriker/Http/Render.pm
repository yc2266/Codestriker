###############################################################################
# Codestriker: Copyright (c) 2001, 2002 David Sitsky.  All rights reserved.
# sits@users.sourceforge.net
#
# This program is free software; you can redistribute it and modify it under
# the terms of the GPL.

# Collection of routines for rendering HTML output.

package Codestriker::Http::Render;

use strict;
use DBI;
use CGI::Carp 'fatalsToBrowser';

# Colour to use when displaying the line number that a comment is being made
# against.
my $CONTEXT_COLOUR = "red";

sub _normal_mode_start( $ );
sub _normal_mode_finish( $ );
sub _coloured_mode_start( $ );
sub _coloured_mode_finish( $ );

# New lines within a diff block.
my @diff_new_lines = ();

# The corresponding lines they refer to.
my @diff_new_lines_numbers = ();

# The corresponding offsets they refer to.
my @diff_new_lines_offsets = ();

# Old lines within a diff block.
my @diff_old_lines = ();

# The corresponding lines they refer to.
my @diff_old_lines_numbers = ();

# The corresponding offsets they refer to.
my @diff_old_lines_offsets = ();

# A record of added and removed lines for a given diff block when displaying a
# file in a popup window, along with their offsets.
my @view_file_minus = ();
my @view_file_plus = ();
my @view_file_minus_offset = ();
my @view_file_plus_offset = ();

# What colour a line should appear if it has a comment against it.
my $COMMENT_LINE_COLOUR = "red";

# Constructor for rendering complex data.
sub new ($$$$$$$\%\@\@$) {
    my ($type, $query, $url_builder, $parallel, $max_digit_width, $topic,
	$mode, $comment_exists_ref, $comment_linenumber_ref,
	$comment_data_ref, $tabwidth) = @_;

    # Record all of the above parameters as instance variables, which remain
    # constant while we render code lines.
    my $self = {};
    $self->{query} = $query;
    $self->{url_builder} = $url_builder;
    $self->{parallel} = $parallel;
    $self->{max_digit_width} = $max_digit_width;
    $self->{topic} = $topic;
    $self->{mode} = $mode;
    $self->{comment_exists_ref} = $comment_exists_ref;
    $self->{comment_linenumber_ref} = $comment_linenumber_ref;
    $self->{comment_data_ref} = $comment_data_ref;
    $self->{tabwidth} = $tabwidth;

    # Also have a number of additional private variables which need to
    # be initialised.
    $self->{diff_current_filename} = "";

    # If required, open the LXR database and read all the identifiers into
    # a massive hashtable (gasp!).
    my %idhash = ();
    if ($Codestriker::lxr_db ne "") {
	my $dbh = DBI->connect($Codestriker::lxr_db, $Codestriker::lxr_user,
			       $Codestriker::lxr_passwd,
			       {AutoCommit=>0, RaiseError=>1})
	    || die "Couldn't connect to database: " . DBI->errstr;
	my $select_ids = $dbh->prepare_cached('SELECT symname FROM symbols');
	$select_ids->execute();
	while (my ($identifier) = $select_ids->fetchrow_array()) {
	    $idhash{$identifier} = 1;
	}
	$dbh->disconnect;
    }
    $self->{idhashref} = \%idhash;

    bless $self, $type;
}

# Given an identifier, wrap it within the appropriate <A HREF> tag if it
# is a known identifier to LXR, otherwise just return the id.  To avoid
# excessive crap, only consider those identifiers which are at least 4
# characters long.
sub lxr_ident($$) {
    my ($self, $id) = @_;
    
    my $idhashref = $self->{idhashref};
    
    if (length($id) >= 4 && defined $$idhashref{$id}) {
	return "<A HREF=\"${Codestriker::lxr_idlookup_base_url}$id\" " .
	    "CLASS=\"fid\">$id</A>";
    } else {
	return $id;
    }
}

# Parse the line and product the appropriate hyperlinks to LXR.
# Currently, this is very Java/C/C++ centric, but it will do for now.
sub lxr_data($$) {
    my ($self, $data) = @_;
    
    # If the line is just a comment, don't do any processing.  Note this code
    # isn't bullet-proof, but its good enough most of the time.
    $_ = $data;
    return $data if (/^(\s|&nbsp;)*\/\// || /^(\s|&nbsp;){0,10}\*/ ||
		     /^(\s|&nbsp;){0,10}\/\*/ ||
		     /^(\s|&nbsp;)*\*\/(\s|&nbsp;)*$/);
    
    # Handle package Java statements.
    if ($data =~ /^(package(\s|&nbsp;)+)([\w\.]+)(.*)$/) {
	return $1 . $self->lxr_ident($3) . $4;
    }
    
    # Handle Java import statements.
    if ($data =~ /^(import(\s|&nbsp;)+)([\w\.]+)\.(\w+)((\s|&nbsp;)*)(.*)$/) {
	return $1 . $self->lxr_ident($3) . "." . $self->lxr_ident($4) . "$5$7";
    }
    
    # Handle #include statements.  Note, these aren't identifier lookups, but
    # need to be mapped to http://localhost.localdomain/lxr/xxx/yyy/incfile.h
    # Should include the current filename in the object for matching purposes.
#    if (/^(\#\s*include\s+[\"<])(.*?)([\">].*)$/) {
#	return $1 . $self->lxr_ident($2) . $3;
#    }
    
    # Break the string into potential identifiers, and look them up to see
    # if they can be hyperlinked to an LXR lookup.
    my $idhashref = $self->{idhashref};
    my @data_tokens = split /([A-Za-z][\w]+)/, $data;
    my $newdata = "";
    my $in_comment = 0;
    my $eol_comment = 0;
    for (my $i = 0; $i <= $#data_tokens; $i++) {
	my $token = $data_tokens[$i];
	if ($token =~ /^[A-Za-z]/) {
	    if ($eol_comment || $in_comment) {
		# Currently in a comment, don't LXRify.
		$newdata .= $token;
	    } else {
		$newdata .= $self->lxr_ident($token);
	    }
	} else {
	    $newdata .= $token;
	    $token =~ s/(\s|&nbsp;)//g;
	    
	    # Check if we are entering or exiting a comment.
	    if ($token =~ /^\/\//) {
		$eol_comment = 1;
	    } elsif ($token =~ /^\/\*/) {
		$in_comment = 1;
	    } elsif ($token =~ /^\*+\//) {
		$in_comment = 0;
	    }
	}
    }

    return $newdata;
}

# Display a line for non-coloured data.
sub display_data ($$$$$$$$$$$) {
    my ($self, $line, $data, $current_file, $current_file_revision,
	$current_old_file_linenumber, $current_new_file_linenumber,
	$reading_diff_block, $diff_linenumbers_found, $cvsmatch,
	$block_description) = @_;
    
    # Escape the data and add LXR links to it.
    $data = $self->lxr_data(CGI::escapeHTML($data));

    # Add the appropriate amount of spaces for alignment before rendering
    # the line number.
    my $digit_width = length($line);
    for (my $j = 0; $j < ($self->{max_digit_width} - $digit_width); $j++) {
	print " ";
    }
    print $self->render_linenumber($line, $line, "", 0);

    # Now render the data.
    print " $data\n";
}

# Display a line for coloured data.  Note special handling is done for
# unidiff formatted text, to output it in the "coloured-diff" style.  This
# requires storing state when retrieving each line.
sub display_coloured_data ($$$$$$$$$$$$$) {
    my ($self, $leftline, $rightline, $offset,
	$data, $current_file, $current_file_revision,
	$current_old_file_linenumber, $current_new_file_linenumber,
	$reading_diff_block, $diff_linenumbers_found, $cvsmatch,
	$block_description) = @_;

    # Don't do anything if the diff block is still being read.  The upper
    # functions are storing the necessary data.
    return if ($reading_diff_block);

    my $query = $self->{query};

    # Escape the data.
    $data = CGI::escapeHTML($data);

    if ($diff_linenumbers_found) {
	if ($self->{diff_current_filename} ne $current_file) {
	    # The filename has changed, render the current diff block (if any)
	    # close the table, and open a new one.
	    $self->render_changes();
	    print $query->end_table();

	    $self->{diff_current_filename} = $current_file;
	    $self->print_coloured_table();

	    my $contents_url =
		$self->{url_builder}->view_url($self->{topic}, -1,
					       $self->{mode}) .	"#contents";
	    if ($cvsmatch) {
		# File matches something is CVS repository.  Link it to
		# the CVS viewer if it is defined.
		my $cell = "";
		my $revision_text = "revision $current_file_revision";
		if ($Codestriker::cvsviewer eq "") {
		    $cell = $query->td({-class=>'file', -colspan=>'3'},
				       "Diff for ",
				       $query->a({name=>"$current_file"},
						 "$current_file"),
				       "$revision_text");
		}
		else {
		    my $url = "$Codestriker::cvsviewer$current_file";
		    $cell = $query->td({-class=>'file', -colspan=>'3'},
				       "Diff for ",
				       $query->a({href=>"$url",
						  name=>"$current_file"},
						 "$current_file"),
				       "$revision_text");
		}
		print $query->Tr($cell,
				 $query->td({-class=>'file', align=>'right'},
					     $query->a({href=>$contents_url},
						       "[Go to Contents]")));
	    } else {
		# No match in repository - or a new file.
		print $query->Tr($query->td({-class=>'file', -colspan=>'3'},
					    "Diff for ",
					    $query->a({name=>"$current_file"},
						      "$current_file")),
				 $query->td({-class=>'file', align=>'right'},
					    $query->a({href=>$contents_url},
						      "[Go to contents]")));
	    }
	}

	print $query->Tr($query->td("&nbsp;"), $query->td("&nbsp;"),
			 $query->td("&nbsp;"), $query->td("&nbsp;"), "\n");

	# Output a diff block description if one is available, in a separate
	# row.
	if ($block_description ne "") {
	    my $description = CGI::escapeHTML($block_description);
	    print $query->Tr($query->td({-class=>'line', -colspan=>'2'},
					$description),
			     $query->td({-class=>'line', -colspan=>'2'},
					$description));
	}
	
	if ($cvsmatch && $Codestriker::cvsrep ne "") {
	    # Display the line numbers corresponding to the patch, with links
	    # to the CVS file.
	    my $url_builder = $self->{url_builder};
	    my $topic = $self->{topic};
	    my $mode = $self->{mode};
	    my $url_old_full =
		$url_builder->view_file_url($topic, $current_file,
					    $UrlBuilder::OLD_FILE,
					    $current_old_file_linenumber,
					    "", $mode);
	    my $url_old = "javascript: myOpen('$url_old_full','CVS')";

	    my $url_old_both_full =
		$url_builder->view_file_url($topic, $current_file,
					    $UrlBuilder::BOTH_FILES,
					    $current_old_file_linenumber,
					    "L", $mode);
	    my $url_old_both =
		"javascript: myOpen('$url_old_both_full','CVS')";

	    my $url_new_full =
		$url_builder->view_file_url($topic, $current_file,
					    $UrlBuilder::NEW_FILE,
					    $current_new_file_linenumber,
					    "", $mode);
	    my $url_new = "javascript: myOpen('$url_new_full','CVS')";

	    my $url_new_both_full =
		$url_builder->view_file_url($topic, $current_file,
					    $UrlBuilder::BOTH_FILES,
					    $current_new_file_linenumber,
					    "R", $mode);
	    my $url_new_both = "javascript: myOpen('$url_new_both_full','CVS')";

	    print $query->Tr($query->td({-class=>'line', -colspan=>'2'},
					$query->a({href=>"$url_old"}, "Line " .
						  "$current_old_file_linenumber") .
					" | " .
					$query->a({href=>"$url_old_both"},
						  "Parallel")),
			     $query->td({-class=>'line', -colspan=>'2'},
					$query->a({href=>"$url_new"}, "Line " .
						  "$current_new_file_linenumber") .
					" | " .
					$query->a({href=>"$url_new_both"},
						  "Parallel"))),
					"\n";
	} else {
	    # No match in the repository - or a new file.  Just display
	    # the headings.
	    print $query->Tr($query->td({-class=>'line', -colspan=>'2'},
					"Line $current_old_file_linenumber"),
			     $query->td({-class=>'line', -colspan=>'2'},
					"Line $current_new_file_linenumber")),
			     "\n";
	}
    }
    else {
	if ($data =~ /^\-(.*)$/) {
	    # Line corresponds to something which has been removed.
	    add_old_change($1, $leftline, $offset);
	} elsif ($data =~ /^\+(.*)$/) {
	    # Line corresponds to something which has been removed.
	    add_new_change($1, $rightline, $offset);
	} elsif ($data =~ /^\\/) {
	    # A diff comment such as "No newline at end of file" - ignore it.
	} else {
	    # Strip the first space off the diff for proper alignment.
	    $data =~ s/^\s//;

	    # Render the previous diff changes visually.
	    $self->render_changes();

	    # Render the current line for both cells.
	    my $celldata = $self->render_coloured_cell($data);
	    my $left_prefix = $self->{parallel} ? "L" : "";
	    my $right_prefix = $self->{parallel} ? "R" : "";

	    # Determine the appropriate classes to render.
	    my $cell_class =
		$self->{mode} == $Codestriker::COLOURED_MODE ? "n" : "msn";

	    my $rendered_left_linenumber =
		$self->render_linenumber($leftline, $offset, $left_prefix);
	    my $rendered_right_linenumber =
		($leftline == $rightline && !$self->{parallel}) ?
		$rendered_left_linenumber :
		$self->render_linenumber($rightline, $offset, $right_prefix);

	    print $query->Tr($query->td($rendered_left_linenumber),
			     $query->td({-class=>$cell_class}, $celldata),
			     $query->td($rendered_right_linenumber),
			     $query->td({-class=>$cell_class}, $celldata),
			     "\n");
	}
    }
}

# Render a cell for the coloured diff.
sub render_coloured_cell($$)
{
    my ($self, $data) = @_;
    
    if (! defined $data || $data eq "") {
	return "&nbsp;";
    }

    # Replace spaces and tabs with the appropriate number of &nbsp;'s.
    $data = tabadjust($self, $self->{tabwidth}, $data, 1);
    $data =~ s/\s/&nbsp;/g;

    # Add LXR links to the output.
    $data = $self->lxr_data($data);

    # Unconditionally add a &nbsp; at the start for better alignment.
    return "&nbsp;$data";
}

# Indicate a line of data which has been removed in the diff.
sub add_old_change($$$) {
    my ($data, $linenumber, $offset) = @_;
    push @diff_old_lines, $data;
    push @diff_old_lines_numbers, $linenumber;
    push @diff_old_lines_offsets, $offset;
}

# Indicate that a line of data has been added in the diff.
sub add_new_change($$$) {
    my ($data, $linenumber, $offset) = @_;
    push @diff_new_lines, $data;
    push @diff_new_lines_numbers, $linenumber;
    push @diff_new_lines_offsets, $offset;
}

# Render the current diff changes, if there is anything.
sub render_changes($) {
    my ($self) = @_;

    return if ($#diff_new_lines == -1 && $#diff_old_lines == -1);

    my ($arg1, $arg2, $arg3, $arg4);
    my $mode = $self->{mode};
    if ($#diff_new_lines != -1 && $#diff_old_lines != -1) {
	# Lines have been added and removed.
	if ($mode == $Codestriker::COLOURED_MODE) {
	    $arg1 = "c"; $arg2 = "cb"; $arg3 = "c"; $arg4 = "cb";
	} else {
	    $arg1 = "msc"; $arg2 = "mscb"; $arg3 = "msc"; $arg4 = "mscb";
	}
    } elsif ($#diff_new_lines != -1 && $#diff_old_lines == -1) {
	# New lines have been added.
	if ($mode == $Codestriker::COLOURED_MODE) {
	    $arg1 = "a"; $arg2 = "ab"; $arg3 = "a"; $arg4 = "ab";
	} else {
	    $arg1 = "msa"; $arg2 = "msab"; $arg3 = "msa"; $arg4 = "msab";
	}
    } else {
	# Lines have been removed.
	if ($mode == $Codestriker::COLOURED_MODE) {
	    $arg1 = "r"; $arg2 = "rb"; $arg3 = "r"; $arg4 = "rb";
	} else {
	    $arg1 = "msr"; $arg2 = "msrb"; $arg3 = "msr"; $arg4 = "msrb";
	}
    }
    $self->render_inplace_changes($arg1, $arg2, $arg3, $arg4);

    # Now that the diff changeset has been rendered, remove the state data.
    @diff_new_lines = ();
    @diff_new_lines_numbers = ();
    @diff_new_lines_offsets = ();
    @diff_old_lines = ();
    @diff_old_lines_numbers = ();
    @diff_old_lines_offsets = ();
}

# Render the inplace changes in the current diff change set.
sub render_inplace_changes($$$$$)
{
    my ($self, $old_col, $old_notpresent_col, $new_col,
	$new_notpresent_col) = @_;

    my $old_data;
    my $new_data;
    my $old_data_line;
    my $new_data_line;
    my $old_data_offset;
    my $new_data_offset;
    while ($#diff_old_lines != -1 || $#diff_new_lines != -1) {

	# Retrieve the next lines which were removed (if any).
	if ($#diff_old_lines != -1) {
	    $old_data = shift @diff_old_lines;
	    $old_data_line = shift @diff_old_lines_numbers;
	    $old_data_offset = shift @diff_old_lines_offsets;
	} else {
	    undef($old_data);
	    undef($old_data_line);
	    undef($old_data_offset);
	}

	# Retrieve the next lines which were added (if any).
	if ($#diff_new_lines != -1) {
	    $new_data = shift @diff_new_lines;
	    $new_data_line = shift @diff_new_lines_numbers;
	    $new_data_offset = shift @diff_new_lines_offsets;
	} else {
	    undef($new_data);
	    undef($new_data_line);
	    undef($new_data_offset);
	}

	my $render_old_data = $self->render_coloured_cell($old_data);
	my $render_new_data = $self->render_coloured_cell($new_data);
	
	# Set the colours to use appropriately depending on what is defined.
	my $render_old_colour = $old_col;
	my $render_new_colour = $new_col;
	if (defined $old_data && ! defined $new_data) {
	    $render_new_colour = $new_notpresent_col;
	} elsif (! defined $old_data && defined $new_data) {
	    $render_old_colour = $old_notpresent_col;
	}

	my $parallel = $self->{parallel};
	my $old_prefix = $parallel ? "L" : "";
	my $new_prefix = $parallel ? "R" : "";

	my $query = $self->{query};
	print $query->Tr($query->td($self->render_linenumber($old_data_line,
							     $old_data_offset,
							     $old_prefix)),
			 $query->td({-class=>"$render_old_colour"},
				    $render_old_data),
			 $query->td($self->render_linenumber($new_data_line,
							     $new_data_offset,
							     $new_prefix)),
			 $query->td({-class=>"$render_new_colour"},
				    $render_new_data), "\n");
    }
}
	
# Render a linenumber as a hyperlink.  If the line already has a
# comment made against it, render it with $comment_line_colour.  The
# title of the link should be set to the comment digest, and the
# status line should be set if the mouse moves over the link.
# Clicking on the link will take the user to the add comment page.
sub render_linenumber($$$$) {
    my ($self, $line, $offset, $prefix) = @_;

    if (! defined $line) {
	return "&nbsp;";
    }

    # Determine what class to use when rendering the number.
    my ($comment_class, $no_comment_class);
    if ($self->{mode} == $Codestriker::COLOURED_MODE) {
	$comment_class = "com";
	$no_comment_class = "nocom";
    } else {
	$comment_class = "smscom";
	$no_comment_class = "smsnocom";
    }

    my $linedata;
    my $comment_exists_ref = $self->{comment_exists_ref};
    if ($offset != -1 && defined $$comment_exists_ref{$offset}) {
	if ($self->{mode} == $Codestriker::NORMAL_MODE) {
	    $linedata = "<FONT COLOR=\"$COMMENT_LINE_COLOUR\">$line</FONT>";
	} else {
	    $linedata = $self->{query}->span({-class=>$comment_class}, $line);
	}
    } else {
	if ($self->{mode} == $Codestriker::NORMAL_MODE) {
	    $linedata = $line;
	} else {
	    $linedata =
		$self->{query}->span({-class=>$no_comment_class}, $line);
	}
    }
    
    # Check if the linenumber is outside the review.
    if ($offset == -1) {
	return $linedata;
    }

    my $link_title = $self->get_comment_digest($offset);
    my $js_title = $link_title;
    $js_title =~ s/\'/\\\'/mg;
    my $anchor = "$prefix$line";
    my $edit_url =
	$self->{url_builder}->edit_url($offset, $self->{topic}, "", $anchor,
				       "");
    $edit_url = "javascript:myOpen('$edit_url','e')";

    my $query = $self->{query};
    if ($link_title ne "") {
	return $query->a(
			 {name=>$anchor,
			  href=>$edit_url,
			  title=>$link_title,
			  onmouseover=>"window.status='$js_title'; " .
			      "return true;"}, $linedata);
    } else {
	return $query->a({name=>$anchor, href=>"$edit_url"}, $linedata);
    }
}

# Generate a string which represents a digest of all the comments made for a
# particular line number.  Used for "tool-tip" windows for line number links
# and/or setting the status bar.
sub get_comment_digest($$) {
    my ($self, $line) = @_;

    my $digest = "";
    my $comment_exists_ref = $self->{comment_exists_ref};
    if ($$comment_exists_ref{$line}) {
	my $comment_linenumber_ref = $self->{comment_linenumber_ref};
	my $comment_data_ref = $self->{comment_data_ref};
	for (my $i = 0; $i <= $#$comment_linenumber_ref; $i++) {
	    if ($$comment_linenumber_ref[$i] == $line) {
		# Need to remove the newlines for the data.
		my $data = $$comment_data_ref[$i];
		$data =~ s/\n/ /mg; # Remove newline characters

		if ($CGI::VERSION < 2.59) {
		    # Gggrrrr... the way escaping has been done between these
		    # versions has changed. This needs to be looked into more
		    # but this does the job for now as a workaround.
		    $data = CGI::escapeHTML($data);
		}
		$digest .= "$data ------- ";
	    }
	}
	# Chop off the last 9 characters.
	substr($digest, -9) = "";
    }
    
    return $digest;
}

# Start hook called when about to start rendering to a page.
sub start($) {
    my ($self) = @_;
    if ($self->{mode} == $Codestriker::NORMAL_MODE) {
	$self->_normal_mode_start();
    } else {
	$self->_coloured_mode_start();
    }
}

# Finished hook called when finished rendering to a page.
sub finish($) {
    my ($self) = @_;
    if ($self->{mode} == $Codestriker::NORMAL_MODE) {
	$self->_normal_mode_finish();
    } else {
	$self->_coloured_mode_finish();
    }
}

# Start topic view display hook for normal mode.
sub _normal_mode_start($) {
    my ($self) = @_;
    print "<PRE>\n";
}

# Finish topic view display hook for normal mode.
sub _normal_mode_finish($) {
    my ($self) = @_;
    print "</PRE>\n";
}

# Start topic view display hook for coloured mode.  This displays a simple
# legend, displays the files involved in the review, and opens up the initial
# table.
sub _coloured_mode_start($) {
    my ($self) = @_;

    my $query = $self->{query};
    my $topic = $self->{topic};
    my $mode = $self->{mode};

    print $query->start_table({-cellspacing=>'0', -cellpadding=>'0',
			       -border=>'0'}), "\n";
    print $query->Tr($query->td("&nbsp;"), $query->td("&nbsp;"));
    print $query->Tr($query->td({-colspan=>'2'}, "Legend:"));
    print $query->Tr($query->td({-class=>'rf'},
				"Removed"),
		     $query->td({-class=>'rb'}, "&nbsp;"));
    print $query->Tr($query->td({-class=>'cf',
				 -align=>"center", -colspan=>'2'},
				"Changed"));
    print $query->Tr($query->td({-class=>'ab'}, "&nbsp;"),
		     $query->td({-class=>'af'},
				"Added"));
    print $query->end_table(), "\n";

    # Print out the "table of contents".  Note, the data should be passed in
    # rather than directly read from here, but this will do for now.  XXX
    my (@filenames, @revisions, @offsets, @binary);
    Codestriker::Model::File->get_filetable($topic, \@filenames,
					    \@revisions, \@offsets, \@binary);
    
    print $query->p;
    print $query->start_table({-cellspacing=>'0', -cellpadding=>'0',
			       -border=>'0'}), "\n";
    print $query->Tr($query->td($query->a({name=>"contents"}, "Contents:")),
		     $query->td("&nbsp;")), "\n";
    
    my $url_builder = $self->{url_builder};
    for (my $i = 0; $i <= $#filenames; $i++) {
	my $filename = $filenames[$i];
	my $revision = $revisions[$i];
	my $href_filename = $url_builder->view_url($topic, -1, $mode) .
	    "#" . "$filename";
	my $tddata = $binary[$i] ? $filename :
	    $query->a({href=>"$href_filename"}, "$filename");
	my $class = "";
	$class = "af" if ($revision eq $Codestriker::ADDED_REVISION);
	$class = "rf" if ($revision eq $Codestriker::REMOVED_REVISION);
	$class = "cf" if ($revision eq $Codestriker::PATCH_REVISION);
 	if ($revision eq $Codestriker::ADDED_REVISION ||
 	    $revision eq $Codestriker::REMOVED_REVISION ||
 	    $revision eq $Codestriker::PATCH_REVISION) {
 	    # Added, removed or patch file.
 	    print $query->Tr($query->td({-class=>"$class", -colspan=>'2'},
 					$tddata)) . "\n";
 	} else {
 	    # Modified file.
 	    print $query->Tr($query->td({-class=>'cf'}, $tddata),
 			     $query->td({-class=>'cf'}, "&nbsp; $revision")) .
 			     "\n";
 	}
    }
    print $query->end_table() . "\n";
    $self->print_coloured_table();
}

# Render the initial start of the coloured table, with an empty row setting
# the widths.
sub print_coloured_table($)
{
    my ($self) = @_;

    my $query = $self->{query};
    print $query->start_table({-width=>'100%',
			       -border=>'0',
			       -cellspacing=>'0',
			       -cellpadding=>'0'}), "\n";
    print $query->Tr($query->td({-width=>'2%'}, "&nbsp;"),
		     $query->td({-width=>'48%'}, "&nbsp;"),
		     $query->td({-width=>'2%'}, "&nbsp;"),
		     $query->td({-width=>'48%'}, "&nbsp;"), "\n");
}


# Finish topic view display hook for coloured mode.
sub _coloured_mode_finish ($) {
    my ($self) = @_;

    # Make sure the last diff block (if any) is written.
    $self->render_changes();

    print "</TABLE>\n";
}

# Print out a line of data with the specified line number suitably aligned,
# and with tabs replaced by spaces for proper alignment.
sub render_monospaced_line ($$$$$$) {
    my ($self, $linenumber, $data, $offset, $max_line_length, $class) = @_;

    my $prefix = "";
    my $digit_width = length($linenumber);
    my $max_digit_width = $self->{max_digit_width};
    for (my $i = 0; $i < ($max_digit_width - $digit_width); $i++) {
	$prefix .= " ";
    }

    # Determine what class to use when rendering the number.
    my ($comment_class, $no_comment_class);
    if ($self->{parallel} == 0) {
	$comment_class = "mscom";
	$no_comment_class = "msnocom";
    } else {
	if ($self->{mode} == $Codestriker::COLOURED_MODE) {
	    $comment_class = "com";
	    $no_comment_class = "nocom";
	} else {
	    $comment_class = "smscom";
	    $no_comment_class = "smsnocom";
	}
    }

    # Render the line data.  If the user clicks on a topic line, the
    # main window is moved to the edit page.  I'm not sure if this is
    # the best thing from a useability perspective, but we'll see for
    # now.
    my $query = $self->{query};
    my $line_cell = "";
    if ($offset != -1) {
	# A line corresponding to the review.
	my $edit_url =
	    $self->{url_builder}->edit_url($offset, $self->{topic}, "",
					   $linenumber, "");
	my $comment_exists_ref = $self->{comment_exists_ref};
	if (defined $$comment_exists_ref{$offset}) {
	    my $link_title = $self->get_comment_digest($offset);
	    my $js_title = $link_title;
	    $js_title =~ s/\'/\\\'/mgo;
	    $line_cell = "$prefix" .
		$query->a({name=>"$linenumber",
			   href=>"javascript:myOpen('$edit_url','e')",
			   title=>$js_title,
			   onmouseover=> "window.status='$js_title'; " .
			       "return true;" },
			  $query->span({-class=>$comment_class},
				       "$linenumber"));
	}
	else {
	    $line_cell = "$prefix" .
		$query->a({name=>"$linenumber",
			   href=>"javascript:myOpen('$edit_url','e')"},
			  $query->span({-class=>$no_comment_class},
				       "$linenumber"));
	}
    }
    else {
	# A line outside of the review.  Just render the line number, as
	# the "name" of the linenumber should not be used.
	$line_cell = "$prefix$linenumber";
    }

    $data = tabadjust($self, $self->{tabwidth}, $data, 0);

    # Add LXR links to the output.
    my $newdata = $self->lxr_data(CGI::escapeHTML($data));

    if ($class ne "") {
	# Add the appropriate number of spaces to justify the data to a length
	# of $max_line_length, and render it within a SPAN to get the correct
	# background colour.
	my $padding = $max_line_length - length($data);
	for (my $i = 0; $i < ($padding); $i++) {
	    $newdata .= " ";
	}
	return "$line_cell " .
	    $query->span({-class=>"$class"}, $newdata) . "\n";
    }
    else {
	return "$line_cell $newdata\n";
    }
}

# Record a plus line.
sub add_plus_monospace_line ($$$) {
    my ($self, $linedata, $offset) = @_;
    push @view_file_plus, $linedata;
    push @view_file_plus_offset, $offset;
}

# Record a minus line.
sub add_minus_monospace_line ($$$) {
    my ($self, $linedata, $offset) = @_;
    push @view_file_minus, $linedata;
    push @view_file_minus_offset, $offset;
}

# Flush the current diff chunk, and update the line count.  Note if the
# original file is being rendered, the minus lines are used, otherwise the
# plus lines.
sub flush_monospaced_lines ($$$$) {
    my ($self, $linenumber_ref, $max_line_length, $new) = @_;

    my $class = "";
    if ($#view_file_plus != -1 && $#view_file_minus != -1) {
	# This is a change chunk.
	$class = "msc";
    }
    elsif ($#view_file_plus != -1) {
	# This is an add chunk.
	$class = "msa";
    }
    elsif ($#view_file_minus != -1) {
	# This is a remove chunk.
	$class = "msr";
    }

    if ($new) {
	for (my $i = 0; $i <= $#view_file_plus; $i++) {
	    print $self->render_monospaced_line($$linenumber_ref,
						$view_file_plus[$i],
						$view_file_plus_offset[$i],
						$max_line_length, $class);
	    $$linenumber_ref++;
	}
    }
    else {
	for (my $i = 0; $i <= $#view_file_minus; $i++) {
	    print $self->render_monospaced_line($$linenumber_ref,
						$view_file_minus[$i],
						$view_file_minus_offset[$i],
						$max_line_length, $class);
	    $$linenumber_ref++;
	}
    }
    $#view_file_minus = -1;
    $#view_file_minus_offset = -1;
    $#view_file_plus = -1;
    $#view_file_plus_offset = -1;
}	

# Replace the passed in string with the correct number of spaces, for
# alignment purposes.
sub tabadjust ($$$$) {
    my ($type, $tabwidth, $input, $htmlmode) = @_;

    $_ = $input;
    if ($htmlmode) {
	1 while s/\t+/'&nbsp;' x
	    (length($&) * $tabwidth - length($`) % $tabwidth)/e;
    }
    else {
	1 while s/\t+/' ' x
	    (length($&) * $tabwidth - length($`) % $tabwidth)/e;
    }
    return $_;
}

# Retrieve the data that forms the "context" when submitting a comment.	
sub get_context ($$$$$\@) {
    my ($type, $line, $topic, $context, $html_view, $document_ref) = @_;

    my @document = @$document_ref;

    # Get the minimum and maximum line numbers for this context, and return
    # the data.  The line of interest will be rendered appropriately.
    my $min_line = ($line - $context < 0 ? 0 : $line - $context);
    my $max_line = $line + $context;
    my $context_string = "";
    for (my $i = $min_line; $i <= $max_line && $i <= $#document; $i++) {
	my $linedata = $document[$i];
	if ($html_view) {
	    if ($i == $line) {
		$context_string .=
		    "<font color=\"$CONTEXT_COLOUR\">" .
		      CGI::escapeHTML($linedata) . "</font>\n";
	    } else {
		$context_string .= CGI::escapeHTML("$linedata") ."\n";
	    }
	} else {
	    $context_string .= ($i == $line) ? "* " : "  ";
	    $context_string .= $linedata . "\n";
	}
    }
    return $context_string;
}

1;
