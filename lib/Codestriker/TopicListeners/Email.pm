###############################################################################
# Codestriker: Copyright (c) 2001, 2002 David Sitsky.  All rights reserved.
# sits@users.sourceforge.net
#
# This program is free software; you can redistribute it and modify it under
# the terms of the GPL.

# Topic Listener for email notification. All email sent from Codestriker
# is sent from this file when an topic event happens.

use strict;

package Codestriker::TopicListeners::Email;

use Codestriker::TopicListeners::TopicListener;
use Net::SMTP;
use Sys::Hostname;

# Separator to use in email.
my $EMAIL_HR = "--------------------------------------------------------------";
# If true, just ignore all email requests.
my $DEVNULL_EMAIL = 0;

@Codestriker::TopicListeners::Email::ISA = ("Codestriker::TopicListeners::TopicListener");

sub new {
    my $type = shift;
    
    # TopicListener is parent class.
    my $self = Codestriker::TopicListeners::TopicListener->new();
    return bless $self, $type;
}

sub topic_create($$) { 
    my ($self, $topic) = @_;
    
    # Send an email to the document author and all contributors with the
    # relevant information.  The person who wrote the comment is indicated
    # in the "From" field, and is BCCed the email so they retain a copy.
    my $from = $topic->{author};
    my $to = $topic->{reviewers};
    my $cc = $topic->{cc};
    my $bcc = $topic->{author};

    # Send out the list of files changes when creating a new topic.
    my (@filenames, @revisions, @offsets, @binary);
    $topic->get_filestable(
    		\@filenames,
                \@revisions,
                \@offsets,
                \@binary);

    my $notes = 
        "Description: \n" .  
	"$topic->{description}\n\n" .
	"$EMAIL_HR\n\n" .
        "The topic was created, the following files were modified.\n" .
        join("\n",@filenames);

    $self->_send_topic_email($topic, "Created", 1, $from, $to, $cc, $bcc,$notes);

    return '';
}

sub topic_changed($$$$) {
    my ($self, $user_that_made_the_change, $topic_orig, $topic) = @_;

    # Not all changes in the topic changes needs to be sent out to everybody
    # who is working on the topic. The policy of this function is that 
    # the following changes will cause an email to be sent. Otherwise,
    # no email will be sent.
    #
    # change in author - sent to the new author, old author, and the person who
    #   made the change.
    # removed reviewer,cc - sent to the removed reviewer, and author if != user.
    # added reviwer,cc - send to the new cc, and author if != user.
    # any change not made by the author, sent to the author.

    # Record the list of email addresses already handled.
    my %handled_addresses = ();

    # First rule, if the author is not one making the change, then the author
    # gets an email no matter what changed.
    if ( $user_that_made_the_change ne $topic->{author} ||
         $user_that_made_the_change ne $topic_orig->{author} ) {
        $handled_addresses{ $topic_orig->{author} } = 1;
        $handled_addresses{ $topic->{author} } = 1;
    }

    # If the author was changed, then the old and new author gets an email.
    if ( $topic->{author} ne $topic_orig->{author}) {
        $handled_addresses{ $topic_orig->{author} } = 1;
        $handled_addresses{ $topic->{author} } = 1;
    }

    # If a reviewer gets removed or added, then they get an email.
    my @new;
    my @removed;

    Codestriker::set_differences( [ split /, /, $topic->{reviewers} ],
                                  [ split /, /, $topic_orig->{reviewers} ],
                                  \@new,\@removed);

    foreach my $user (@removed) {
        $handled_addresses{ $user } = 1;
    }

    foreach my $user (@new) {
        $handled_addresses{ $user } = 1;
    }

    # If a CC gets removed or added, then they get an email.
    @new = ();
    @removed = ();

    Codestriker::set_differences( [ split /, /, $topic->{cc} ], 
                                  [ split /, /, $topic_orig->{cc} ],
                                  \@new,\@removed);

    foreach my $user (@removed) {
        $handled_addresses{ $user } = 1;
	}

    foreach my $user (@new) {
        $handled_addresses{ $user } = 1;
    }

    my @to_list = keys( %handled_addresses );

    if ( @to_list ) {
        $self->send_topic_changed_email($user_that_made_the_change, 
                    $topic_orig, $topic,@to_list);
	}

    return '';
}

# This function is like topic_changed, except it expects a list of people
# to send the email to as the last set of parameters. It diff's the two topics
# and lists the changes made to the topic in the email. The caller is responsible
# for figuring out if an email is worth sending out, this function is responsible
# for the content of the email only.
sub send_topic_changed_email {
    my ($self, $user_that_made_the_change, $topic_orig, $topic,@to_list) = @_;

    my $changes;

    # First line is naming names on who made the change to the topic.
    if ($user_that_made_the_change ne "") {
        $changes .= "The following changes were made by $user_that_made_the_change.\n";
    }
    else {
        my $host = $ENV{'REMOTE_HOST'};
	my $addr = $ENV{'REMOTE_ADDR'};

        $host = "(unknown)" if !defined($host);
	$addr = "(unknown)" if !defined($addr);

        $changes .= "The following changes were made by an unknown user from " . 
                    "host $host and address $addr\n";
    }

    # Check for author change.
    if ($topic->{author} ne $topic_orig->{author}) {
        $changes .= "Author changed from " . 
            $topic_orig->{author} . " to " . $topic->{author} . "\n";
    }

    # Check for changes in the reviewer list.
    my @new;
    my @removed;

    Codestriker::set_differences( [ split /, /, $topic->{reviewers} ],
                                  [ split /, /, $topic_orig->{reviewers} ],
                                  \@new,\@removed);
    foreach my $user (@removed) {
        $changes .= "The reviewer $user was removed.\n";
    }

    foreach my $user (@new) {
        $changes .= "The reviewer $user was added.\n";
    }

    # Check for changes in the cc list.
    @new = ();
    @removed = ();

    Codestriker::set_differences( [ split /, /, $topic->{cc} ], 
                                  [ split /, /, $topic_orig->{cc} ],
                                  \@new,\@removed);

    foreach my $user (@removed) {
        $changes .= "The cc $user was removed.\n";
    }

    foreach my $user (@new) {
        $changes .= "The cc $user was added.\n";
    }

    # Check for title change.
    if ($topic->{title} ne $topic_orig->{title} ) {
        $changes .= "The title was changed to $topic->{title}.\n";
    }

    # Check for repository change.
    if ($topic->{repository} ne $topic_orig->{repository}) {
        $changes .= "The repository was changed to $topic->{repository}.\n";
    }

    # Check for description change.
    if ($topic->{description} ne $topic_orig->{description} ) {
        $changes .= "The description was changed.\n";
    }

    # Check for state changes
    if ($topic->{topic_state} ne $topic_orig->{topic_state} ) {
        $changes .= "The state was changed to $topic->{topic_state}.\n";
    }

    if ($topic->{project_name} ne $topic_orig->{project_name}) {
        $changes .= "The project was changed to $topic->{project_name}.\n";
    }

    if ($topic->{bug_ids} ne $topic_orig->{bug_ids}) {
        $changes .= "The bug list was changed to $topic->{bug_ids}.\n";
    }

    # See if anybody needs an mail, if so then send it out.
    if (@to_list) {
        my $from = $user_that_made_the_change;
        my $bcc = "";

        if ($user_that_made_the_change eq "") {
            $from = $topic->{author};
        }
        else {
            $bcc = $user_that_made_the_change;
        }

        # Remove the $user_that_made_the_change, they are bcc'ed, don't want to
        # send the email out twice.
        my @final_to_list;

        foreach my $user (@to_list) {
            push (@final_to_list,$user) if $user ne $user_that_made_the_change;
        }
        
        if (@to_list > 0 && @final_to_list == 0) {
            push(@final_to_list, $user_that_made_the_change);
            $bcc = "";
        }

        my $to = join ', ', sort @final_to_list;
        my $cc = "";

        # Send off the email to the revelant parties.
        $self->_send_topic_email($topic, "Modified", 1, $from, 
                $to, $cc, $bcc,$changes);
    }
}

sub comment_create($$$) {
    my ($self, $topic, $comment) = @_;
        
    my $query = new CGI;
    my $url_builder = Codestriker::Http::UrlBuilder->new($query);
    
    # Send an email to the document author and all contributors with the
    # relevant information.  The person who wrote the comment is indicated
    # in the "From" field, and is BCCed the email so they retain a copy.
    my $edit_url = $url_builder->edit_url($comment->{filenumber}, 
					  $comment->{fileline}, 
					  $comment->{filenew},
					  $comment->{topicid}, "", "",
					  $query->url());

    # Retrieve the diff hunk for this file and line number.
    my $delta = Codestriker::Model::Delta->get_delta(
                    $comment->{topicid}, 
                    $comment->{filenumber}, 
		    $comment->{fileline}, 
		    $comment->{filenew});

    # Retrieve the comment details for this topic.
    my @comments = $topic->read_comments();

    my %contributors = ();
    $contributors{$comment->{author}} = 1;
    my @cc_recipients;
    for (my $i = 0; $i <= $#comments; $i++) {
	if ( $comments[$i]{fileline} == $comment->{fileline} &&
	     $comments[$i]{filenumber} == $comment->{filenumber} &&
	     $comments[$i]{filenew} == $comment->{filenew} &&
	     $comments[$i]{author} ne $topic->{author} &&
	     ! exists $contributors{$comments[$i]{author}}) {
	    $contributors{$comments[$i]{author}} = 1;
	    push(@cc_recipients, $comments[$i]{author});
	}
    }
        
    push @cc_recipients, (split ',', $comment->{cc});
       
    my $from = $comment->{author};
    my $to = $topic->{author};
    my $bcc = $comment->{author};
    my $subject = "[REVIEW] Topic \"$topic->{title}\" comment added by $comment->{author}";
    my $body =
	"$comment->{author} added a comment to Topic \"$topic->{title}\".\n\n" .
	"URL: $edit_url\n\n";

    $body .= "File: " . $delta->{filename} . " line $comment->{fileline}.\n\n";

    $body .= "Context:\n$EMAIL_HR\n\n";
    my $email_context = $Codestriker::EMAIL_CONTEXT;
    $body .= Codestriker::Http::Render->get_context($comment->{fileline}, 
						    $email_context, 0,
						    $delta->{old_linenumber},
						    $delta->{new_linenumber},
						    $delta->{text}, 
						    $comment->{filenew})
	. "\n";
    $body .= "$EMAIL_HR\n\n";    
    
    # Now display the comments that have already been submitted.
    for (my $i = $#comments; $i >= 0; $i--) {
	if ($comments[$i]{fileline} == $comment->{fileline} &&
	    $comments[$i]{filenumber} == $comment->{filenumber} &&
	    $comments[$i]{filenew} == $comment->{filenew}) {
	    my $data = $comments[$i]{data};

	    $body .= "$comments[$i]{author} $comments[$i]{date}\n\n$data\n\n";
	    $body .= "$EMAIL_HR\n\n";    
	}
    }

    # Send the email notification out, if it is allowed in the config file.
    if ( $Codestriker::allow_comment_email || $comment->{cc} ne "")
    {
	if (!$self->doit(0, $comment->{topicid}, $from, $to,
			join(',',@cc_recipients), $bcc,
			$subject, $body)) {
	    return "Failed to send topic creation email";
        }
    }
    
    return '';    
}

# This is a private helper function that is used to send topic emails. Topic 
# emails include topic creation, state changes, and deletes.
sub _send_topic_email {
    my ($self, $topic, $event_name, $include_url, $from, $to, $cc, $bcc, $notes) = @_;
  
    my $query = new CGI;
    my $url_builder = Codestriker::Http::UrlBuilder->new($query);
    my $topic_url = $url_builder->view_url_extended($topic->{topicid}, -1, 
						    "", "", "",
						    $query->url(), 0);
    
    my $subject = "[REVIEW] Topic $event_name \"" . $topic->{title} . "\" \n";
    my $body =
	"Topic \"$topic->{title}\"\n" .
	"Author: $topic->{author}\n" .
	(($topic->{bug_ids} ne "") ? "Bug IDs: $topic->{bug_ids}\n" : "") .
	"Reviewers: $topic->{reviewers}\n" .
        (($include_url) ? "URL: $topic_url\n\n" : "") .
	"$EMAIL_HR\n" .
        $notes;

    # Send the email notification out.
    $self->doit(1, $topic->{topicid}, $from, $to, $cc, $bcc, $subject, $body);
}

# Send an email with the specified data.  Return false if the mail can't be
# successfully delivered, true otherwise.
sub doit($$$$$$$$$) {
    my ($type, $new, $topicid, $from, $to, $cc, $bcc, $subject, $body) = @_;

    return 1 if ($DEVNULL_EMAIL);
    
    my $smtp = Net::SMTP->new($Codestriker::mailhost);
    defined $smtp || die "Unable to connect to mail server: $!";

    $smtp->mail($from);
    $smtp->ok() || die "Couldn't set sender to \"$from\" $!, " .
	$smtp->message();

    # $to has to be defined.
    my $recipients = $to;
    $recipients .= ", $cc" if $cc ne "";
    $recipients .= ", $bcc" if $bcc ne "";
    my @receiver = split /, /, $recipients;
    for (my $i = 0; $i <= $#receiver; $i++) {
	$smtp->recipient($receiver[$i]);
	$smtp->ok() || die "Couldn't send email to \"$receiver[$i]\" $!, " .
	    $smtp->message();
    }

    $smtp->data();
    $smtp->datasend("From: $from\n");
    $smtp->datasend("To: $to\n");
    $smtp->datasend("Cc: $cc\n") if $cc ne "";

    # If the message is new, create the appropriate message id, otherwise
    # construct a message which refers to the original message.  This will
    # allow for threading, for those email clients which support it.
    my $message_id = "<Codestriker-" . hostname() . "-${topicid}>";

    if ($new) {
	$smtp->datasend("Message-Id: $message_id\n");
    } else {
	$smtp->datasend("References: $message_id\n");
	$smtp->datasend("In-Reply-To: $message_id\n");
    }

    $smtp->datasend("Subject: $subject\n");

    # Insert a blank line for the body.
    $smtp->datasend("\n");
    $smtp->datasend($body);
    $smtp->dataend();
    $smtp->ok() || die "Couldn't send email $!, " . smtp->message();

    $smtp->quit();
    $smtp->ok() || die "Couldn't send email $!, " . smtp->message();

    return 1;
}

1;
