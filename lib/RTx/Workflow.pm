# $File: //depot/RT/rt/lib/RT/CustomField_Local.pm $ $Author: autrijus $
# $Revision: #1 $ $Change: 2542 $ $DateTime: 2002/12/02 01:29:20 $

package RT::Workflow;
our $VERSION = '0.00_01';

use strict;
use File::Basename 'dirname';
use lib dirname(__FILE__) . '/../';
use RT::WorkflowEntry;

sub new {
    my ($class, $CurrentUser) = @_;
    return bless({ CurrentUser => $CurrentUser, Entries => {} }, $class);
}

sub Id { '' }

sub Load {
    my ($self, $id) = @_;
    ($self->{TemplateObj} = RT::Template->new($self->CurrentUser))->Load($id);
    $self->Parse;
    $self->TemplateObj->SetContent($self->Dump);
}

sub SetSubject { }
sub Subject { '' }

sub Save {
    my $self =shift;
    $self->TemplateObj->SetContent($self->Dump);
}

sub Create {
    my ($self, %args) = @_;
    my $name = ($args{Queue} ? "DefaultApproval" : "GlobalApproval");
    $args{Name} = $name;
    $args{Description} = $name;
    $self->{TemplateObj} = RT::Template->new($self->CurrentUser);
    $self->TemplateObj->Create(%args);
    $self->TemplateObj->SetContent($self->Dump);
}

sub TemplateObj { $_[0]->{TemplateObj} }
sub CurrentUser { $_[0]->{CurrentUser} }
sub Entries     { $_[0]->{Entries} }
sub ChildrenRecursive { $_[0]->{Entries} }

sub Children {
    my $self = shift;
    my @root;
    foreach my $Id (sort keys %{$self->{Entries}||{}}) {
	my $Entry = $self->{Entries}{$Id};
	push @root, $Entry if $Entry->{IsEntryPoint};
    }
    return \@root;
}

sub HasChild {
    my ($self, $Entry) = @_;
    $Entry = $Entry->Id if UNIVERSAL::can($Entry, 'Id');
    return grep { $_->Id eq $Entry } @{$self->Children};
}

sub HasChildRecursive {
    my ($self, $Entry) = @_;
    $Entry = $Entry->Id if UNIVERSAL::can($Entry, 'Id');
    return $self->ChildrenRecursive->{$Entry};
}

sub DeleteChild {
    my ($self, $id) = @_;
    delete $self->Entries->{$id};
    $self->Parse($self->Dump);
}

sub Parse {
    my ($self, $content) = @_;
    #if (open(my $fh, '/tmp/x')) { local $/; $content = <$fh> }
    $content ||= $self->TemplateObj->Content or return;

    my (%E, %e, @e, %dep, %rev);
    %{$self->{Entries}} = ();

    foreach (sort split(/^ENDOFCONTENT\n*/m, $content)) {
	my $Entry = RT::WorkflowEntry->new($self->CurrentUser);
	$Entry->Parse($_) or next;
	$Entry->{IsEntryPoint} = 0;
	$Entry->{_workflow} = $self;
	my $id = $Entry->Id or next;
	$e{$id} = $Entry;
	push @{$rev{$_}}, $id for split(/,/, $Entry->{NextStates});
	push @e, $Entry;
    }

    # now starts fixing stuff
    my @Top = grep !@{$rev{$_->Id}||[]}, @e;
    my $id = 0;
    foreach my $e (@Top) {
	$e->{IsEntryPoint} = 1;
	$self->walk($e, \%e, '', \$id, \%E, 0);
    }

    while (my ($k, $v) = each %E) {
	$v->{Id} = delete $v->{NewId};
    }

    %{$self->{Entries}} = %E;
    return $self;
}

sub condition {
    my ($top, $satisfy, $condition) = @_;
    $RT::Logger->debug("Checking cond: @_\n");

    if ($satisfy eq 'BEGIN') {
	return 0 if @T::AllID < 2;  # don't run BEGIN if there's nothing else
	return 1;
    }

    my $Requestor = eval { $top->Requestors->UserMembersObj->ItemsArrayRef->[0] } or return 0;

    my %cond = split(/,/, $condition) or return 1;
    if (my $code = delete $cond{code}) {
	# XXX: check code+fields using the sp_call plan
	my $fields = $cond{fields} || '';
	return action($top, $code, $fields, 1);
    }

    delete $cond{fields};
    return 1 unless %cond;

    while (my ($k, $v) = each %cond) {
	my $ok;
	if ($k =~ s/Begin//) {
	    $ok = 1 if $Requestor->val($k) le $v;
	}
	elsif ($k =~ s/End//) {
	    $ok = 1 if $Requestor->val($k) ge $v;
	}
	else {
	    $ok = 1 if $Requestor->val($k) eq $v;
	}
	$RT::Logger->debug("cond: $k against $v for " . $Requestor->val($k) . ": $ok\n");
	return 0 if !$ok and $satisfy eq 'all';
	return 1 if $ok and $satisfy eq 'any';
    }

    $RT::Logger->debug("cond: fallback, returning zero");
    return 0;
}

sub action {
    my ($top, $key, $fields, $no_die) = @_;

    if ($key eq 'AutoResolve') {
	$top->SetStatus(
	    Status	=> 'resolved',
	    Force	=> 1,
	);
	return 1;
    }
    elsif ($key eq 'AutoReject') {
	die "AutoReject";
    }

    my $Requestor = eval { $top->Requestors->UserMembersObj->ItemsArrayRef->[0] } or return 0;
    my @fields;
    foreach my $id (split(/[,.]/, $fields)) {
	my $Values = $top->CustomFieldValues($id);
	my $out = '';
	while (my $Value = $Values->Next) {
	    $out .= RT::User->escaped($Value->Content) . ",";
	}
	chop $out;
	push @fields, $out;
    }

    my $rv = eval { $Requestor->call_sp($key, \@fields, $top) };

    if ($@) {
	$rv = Encode::decode(big5 => $@);
	$rv =~ s/ at .*//s;
	return 0 if $no_die;
    }

    return $rv if $no_die;
    return 1 unless $rv;

    $top->Correspond(
	Content     => (("Input error") . ": " . $rv),
	_reopen     => 0,
    );
#    $top->SetStatus(
#	Status	=> 'resolved',
#	Force	=> 1,
#    );

    die $rv;
}

sub owner {
    my ($top, $class, $fields) = @_;
    my %fields = split(/,/, $fields);

    $RT::Logger->debug("owner called: @_");
    if ($class eq 'owner') {
	return eval { $top->OwnerObj->Id } || $top->QueueObj->AdminCc->UserMembersObj->ItemsArrayRef->[0]->Id;
    }

    my $Requestor = eval { $top->Requestors->UserMembersObj->ItemsArrayRef->[0] } or return 0;

    if ($class eq 'admin') {
	my @levels = qw(topic_first_boss_id topic_first_boss_id topic_second_boss_id topic_second_boss topic_second_boss);
	my $key = $levels[$fields{admin}] or die "Invalid level: $fields{admin}";
	my $id = $Requestor->val($key) or die "No $key for requestor " . $Requestor->Name;
	my $User = RT::User->new($RT::SystemUser);
	$User->LoadByCols( ExternalAuthId => $id );
	die "Cannot load user id $id" unless $User->Id;

	if ($fields{admin} > 2) {
	    my $key = $levels[$fields{admin} - 2] or die "Invalid level: $fields{admin}";
	    my $id = $User->val($key) or die "No $key for 2nd-level boss " . $User->Name;
	    $User = RT::User->new($RT::SystemUser);
	    $User->LoadByCols( ExternalAuthId => $id );
	    die "Cannot load user id $id" unless $User->Id;
	}
	return $User->Id;
    }
    elsif ($class eq 'customfield') {
	my $User = RT::User->new($RT::SystemUser);
	my $Value = eval { $top->CustomFieldValues($fields{customfield})->First->Content }
	    or die "No value for $fields{customfield}: $@";

	# ok, now the userid belongs to a CF. it's either an ExternalAuthId or a Name.
	if ($Value eq int($Value)) {
	    $User->LoadByCols( ExternalAuthId => $Value );
	}
	else {
	    $User->LoadByCols( Name => $Value );
	}
	die "Cannot load user from $Value" unless $User->Id;
	return $User->Id;
    }
    
    my $Role;
    my $Group = RT::Group->new($RT::SystemUser);

    if ($class eq 'ownrole') {
	$Role = $fields{ownrole} or die "No role specified";
	my $dept = $Requestor->val('department') or die "No dept for requestor";
	$Group->LoadByCols(
	    Domain	=> 'UserDefined',
	    Description	=> $dept,
	);
    }
    elsif ($class eq 'grouprole') {
	$Role = $fields{role} or die "No role specified";
	$Group->Load($fields{group});
    }

    die "Cannot load group for requestor" unless $Group->Id;

    # now walk group members and find somebody that fits the role
    # maybe handle AdminCc here, sometimes in the future...
    my $CurrentUser = RT::CurrentUser->new;
    $CurrentUser->Load( $Requestor->Id );
    my $RoleMap = RT::Groups->new($CurrentUser)->RoleMap;

    my $Users = $Group->UserMembersObj;
    while (my $User = $Users->Next) {
	next if $User->Id eq $Requestor->Id;
	if ($Role > 0) {
	    next unless $User->val('job') eq $Role;
	}
	else {
	    next unless eval { $RoleMap->{$Group->Id}{-$Role}{$User->Id} };
	}
	return $User->Id;
    }

    die "Cannot find role $Role within group " . $Group->Name;
}

sub Dump {
    my $self = shift;
    my $dump = << 'EOF';
===Create-Ticket: BEGIN
### BEGIN ### { require RT::Workflow; %X = () } ###############################
# {eval \{ RT::Workflow::condition($Tickets\{TOP\}, 'BEGIN') \} or die "=$@"} #
###############################################################################
Subject: BEGIN #{$Tickets\{TOP\}->Id}
Queue: ___Approvals
Type: code
Status: resolved
Content:
"BEGIN #{$Tickets\{TOP\}->Id}"
ENDOFCONTENT

EOF

    foreach my $Id (sort keys %{$self->{Entries}||{}}) {
	$dump .= $self->{Entries}{$Id}->Dump;
    }
    return $dump;
}

sub walk {
    my ($self, $item, $old_list, $prefix, $id_ref, $new_list, $depth) = @_;
    return if $depth > 20; # recursion prevention

    my $id = $item->{NewId};
    $item->{NewId} = $id = $prefix . (++$$id_ref) unless $id;
    return if $new_list->{$id};
    $new_list->{$id} = $item;

    my $child = 0;
    foreach my $dep (split(/,/, $item->{NextStates})) {
	my $D = $old_list->{$dep} or next;
	push @{$item->{_next}}, $D;
	$D->{NewId} and next;
	$D->{NewId} = "$id." . ++$child;
    }
    $self->walk($_, $old_list, '', '', $new_list, $depth+1) for @{$item->{_next}};

    $item->{NextStates} = join(',', map $_->{NewId}, @{$item->{_next}});
}

eval "require RT::Workflow_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Workflow_Vendor.pm});
eval "require RT::Workflow_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/Workflow_Local.pm});

1;
