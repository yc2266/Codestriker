###############################################################################
# Codestriker: Copyright (c) 2001, 2002 David Sitsky.  All rights reserved.
# sits@users.sourceforge.net
#
# This program is free software; you can redistribute it and modify it under
# the terms of the GPL.

# Action object for handling the submission of a new topic.

package Codestriker::Action::SubmitTopic;

use strict;

use Codestriker::Model::Topic;
use Codestriker::Smtp::SendEmail;
use Codestriker::Http::Render;
use Codestriker::BugDB::BugDBConnectionFactory;
use Codestriker::Repository::RepositoryFactory;
use Codestriker::FileParser::Parser;

# If the input is valid, create the appropriate topic into the database.
sub process($$$) {
    my ($type, $http_input, $http_response) = @_;

    my $query = $http_response->get_query();

    # Check that the appropriate fields have been filled in.
    my $topic_title = $http_input->get('topic_title');
    my $topic_description = $http_input->get('topic_description');
    my $reviewers = $http_input->get('reviewers');
    my $email = $http_input->get('email');
    my $cc = $http_input->get('cc');
    my $fh = $http_input->get('fh');
    my $topic_file = $http_input->get('fh_filename');
    my $bug_ids = $http_input->get('bug_ids');
    my $repository_url = $http_input->get('repository');

    my $feedback = "";
    my $topic_text = "";

    if ($topic_title eq "") {
	$feedback .= "No topic title was entered.\n";
    }
    if ($topic_description eq "") {
	$feedback .= "No topic description was entered.\n";
    }
    if ($email eq "") {
	$feedback .= "No email address was entered.\n";
    }	
    if (!defined $fh) {
	$feedback .= "No filename was entered.\n";
    }
    if ($reviewers eq "") {
	$feedback .= "No reviewers were entered.\n";
    }

    $http_response->generate_header("", "Create new topic", $email, $reviewers,
				    $cc, "", "", $repository_url, "", 0, 0);

    # If there is a problem with the input, redirect to the create screen
    # with the message.
    if ($feedback ne "") {
	$feedback =~ s/\n/<BR>/g;
	my $vars = {};
	$vars->{'version'} = $Codestriker::VERSION;
	$vars->{'feedback'} = $feedback;
	$vars->{'email'} = $email;
	$vars->{'reviewers'} = $reviewers;
	$vars->{'cc'} = $cc;
	$vars->{'allow_repositories'} = $Codestriker::allow_repositories;
	$vars->{'topic_file'} = $topic_file;
	$vars->{'topic_description'} = $topic_description;
	$vars->{'topic_title'} = $topic_title;
	$vars->{'bug_ids'} = $bug_ids;
	$vars->{'default_repository'} = $repository_url;
	$vars->{'repositories'} = \@Codestriker::valid_repositories;
	
	my $template = Codestriker::Http::Template->new("createtopic");
	$template->process($vars) || die $template->error();
	return;
    }	

    # Set the repository to the default if it is not entered.
    if ($repository_url eq "") {
	$repository_url = $Codestriker::valid_repositories[0];
    }

    # Check if the repository argument is valid.
    my $repository =
	Codestriker::Repository::RepositoryFactory->get($repository_url);

    # Try to parse the topic text into its diff chunks.
    my @deltas =
	Codestriker::FileParser::Parser->parse($fh, "text/plain", $repository);

    # If the topic text has been uploaded from a file, read from it now.
    if (defined $fh) {
	while (<$fh>) {
	    $topic_text .= $_;
	}
	if ($topic_text eq "") {
	    $http_response->error("Uploaded file doesn't exist or is empty!");
	}
    }

    # Remove \r from the topic text.
    $topic_text =~ s/\r//g;

    # For "hysterical" reasons, the topic id is randomly generated.  Seed the
    # generator based on the time and the pid.  Keep searching until we find
    # a free topicid.  In 99% of the time, we will get a new one first time.
    srand(time() ^ ($$ + ($$ << 15)));
    my $topicid;
    do {
	$topicid = int rand(10000000);
    } while (Codestriker::Model::Topic->exists($topicid));

    # Create the topic in the model.
    my $timestamp = Codestriker->get_timestamp(time);
    Codestriker::Model::Topic->create($topicid, $email, $topic_title,
				      $bug_ids, $reviewers, $cc,
				      $topic_description, $topic_text,
				      $timestamp, $repository, \@deltas);

    # Obtain a URL builder object and determine the URL to the topic.
    my $url_builder = Codestriker::Http::UrlBuilder->new($query);
    my $topic_url = $url_builder->view_url_extended($topicid, -1, "", "", "",
						    $query->url(), 0);

    # Send an email to the document author and all contributors with the
    # relevant information.  The person who wrote the comment is indicated
    # in the "From" field, and is BCCed the email so they retain a copy.
    my $from = $email;
    my $to = $reviewers;
    my $bcc = $email;
    my $subject = "[REVIEW] Topic \"$topic_title\" created\n";
    my $body =
	"Topic \"$topic_title\" created\n" .
	"Author: $email\n" .
	(($bug_ids ne "") ? "Bug IDs: $bug_ids\n" : "") .
	"Reviewers: $reviewers\n" .
	"URL: $topic_url\n\n" .
	"Description:\n" .
	"$Codestriker::Smtp::SendEmail::EMAIL_HR\n\n" .
	"$topic_description\n";

    # Send the email notification out.
    if (!Codestriker::Smtp::SendEmail->doit(1, $topicid, $from, $to, $cc, $bcc,
					    $subject, $body)) {
	$http_response->error("Failed to send topic creation email");
    }

    # If Codestriker is linked to a bug database, and this topic is associated
    # with some bugs, update them with an appropriate message.
    if ($bug_ids ne "" && $Codestriker::bug_db ne "") {
	my $bug_db_connection =
	    Codestriker::BugDB::BugDBConnectionFactory->getBugDBConnection();
	$bug_db_connection->get_connection();
	my @ids = split /, /, $bug_ids;
	my $text = "Codestriker topic: $topic_url created.\n" .
	    "Author: $email\n" .
	    "Reviewer(s): $reviewers\n" .
	    "Title: $topic_title\n";
	for (my $i = 0; $i <= $#ids; $i++) {
	    $bug_db_connection->update_bug($ids[$i], $text);
	}
	$bug_db_connection->release_connection();
    }

    # Indicate to the user that the topic has been created and an email has
    # been sent.
    my $vars = {};
    $vars->{'version'} = $Codestriker::VERSION;
    $vars->{'topic_title'} = $topic_title;
    $vars->{'email'} = $email;
    $vars->{'topic_url'} = $topic_url;
    $vars->{'reviewers'} = $reviewers;
    $vars->{'cc'} = (defined $cc) ? $cc : "";

    my $template = Codestriker::Http::Template->new("submittopic");
    $template->process($vars) || die $template->error();
}

1;
