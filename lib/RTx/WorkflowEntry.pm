# $File: //depot/RT/rt/lib/RT/CustomField_Local.pm $ $Author: autrijus $
# $Revision: #1 $ $Change: 2542 $ $DateTime: 2002/12/02 01:29:20 $

package RT::WorkflowEntry;

my @Keys = qw(
    AdminCc Subject Type NextStates IsEntryPoint Queue
    ConditionSatisfy ConditionFields
    ActionProcedure ActionFields
    OwnerClass OwnerFields
);
foreach my $key (@Keys) {
    *{$key} = sub { $_[0]{$key} };
    *{"Set$key"} = sub { $_[0]{$key} = $_[1] };
}

use strict;
sub new {
    my ($class, $CurrentUser) = @_;
    return bless({ _current_user => $CurrentUser }, $class);
}

sub Id { $_[0]{Id} }
sub CurrentUser { $_[0]{_current_user} }
sub Children { $_[0]{_next} }
sub WorkflowObj { $_[0]{_workflow} }

sub Parents {
    my $self = shift;
    my $WF = $self->WorkflowObj;
    return grep {
	grep { $_->Id eq $self->Id } @{$_->{_next}}
    } map {
	$WF->Entries->{$_}
    } (sort keys %{$WF->Entries});
}

sub HasSibling {
    my ($self, $Entry) = @_;
    my $WF = $self->WorkflowObj;
    $Entry = $Entry->Id if UNIVERSAL::can($Entry, 'Id');

    return grep {
	( grep { $_->Id eq $self->Id } @{$_->{_next}} and
	  grep { $_->Id eq $Entry } @{$_->{_next}}) or
	( $self->IsEntryPoint and
	  $WF->Entries->{$Entry}->IsEntryPoint )
    } map {
	$WF->Entries->{$_}
    } (sort keys %{$WF->Entries});
}

sub HasChild { goto &RT::Workflow::HasChild };
sub HasChildRecursive { goto &RT::Workflow::HasChildRecursive };

sub ChildrenRecursive {
    my ($self, $seen) = @_;
    $seen ||= {};
    return if $seen->{$self->Id}++;

    foreach my $Entry (@{$self->Children}) {
	$Entry->ChildrenRecursive($seen);
    }
    
    return $seen;
}

sub DeleteChild {
    my ($self, $id) = @_;
    my $WF = $self->WorkflowObj;
    my $Child = $WF->Entries->{$id};

    my %seen;
    $self->SetNextStates(
	join(',', grep {
	    $_ ne $id and !$seen{$_}++
	} (
	    split(/,/, $self->NextStates),
	    split(/,/, $Child->NextStates),
	) )
    );

    delete $WF->Entries->{$id} unless $Child->Parents > 1;
    $WF->Parse($WF->Dump);
}

sub Create {
    my ($self, %args)= @_;
    # ...
    # also set_parent here?
}

sub Delete {
    my $self = shift;
    my $WF = $self->WorkflowObj;
    delete $WF->Entries->{$self->Id};

    my @children = split(/,/, $self->NextStates);
    foreach my $Id (sort keys %{$WF->Entries}) {
	my $Entry = $WF->Entries->{$Id};
	next unless grep {$_->Id eq $self->Id} @{$Entry->{_next}};
	my %seen;
	$Entry->SetNextStates(
	    join(',', grep {
		($_ ne $self->Id) and (!$seen{$_}++)
	    } (split(/,/, $Entry->NextStates), @children))
	);
    }

    $WF->Parse($WF->Dump);
}

sub Parse {
    my ($self, $content) = @_;
    return unless $content =~ /^===Create-Ticket: T(.*)$/m;

    $self->{Id} = $1;
    $self->{Queue} = '___Approvals';

    if ($content =~ /^Owner: (.*)$/m) {
	my $User = RT::User->new($self->CurrentUser);
	$User->Load( $1 );
	$self->{Owner} = $User->Id;
    }
    if ($content =~ /^Queue: (.*)$/m) {
	my $Queue = RT::Queue->new($self->CurrentUser);
	$Queue->Load( $1 );
	$self->{Queue} = $Queue->Id;
    }

    foreach my $key (@Keys) {
	$self->{$key} = $1 if $content =~ /^$key: (.*)$/m;
    }

    my @N;
    my %seen;
    foreach my $n (split(/,/, $self->{NextStates})) {
	next unless $n;
	push @N, $n unless $seen{$n}++;
    }
    $self->{NextStates} = join(',', @N);
    $self->{Content} = $1 if $content =~ /^Content: ?\n+(.*?)\n*\Z/ms;
    $self->{_top} = 1;

    return $self;
}

sub Dump {
    my $self = shift;

    my ($Queue, $Owner, $AdminCc) = (
	RT::Queue->new($self->CurrentUser),
	RT::User->new($self->CurrentUser),
	RT::Principal->new($self->CurrentUser),
    );

    $Queue->Load( $self->{Queue} );
    $Owner->Load( $self->{Owner} );
    $AdminCc->Load( $self->{AdminCc} ) unless $self->{AdminCc} == -1; # special!

    my $res = << "EOF";
===Create-Ticket: T$self->{Id}
EOF

    $res .= << "EOF";
### CONDITION ### { require RT::Workflow } ####################################
## { eval \\{ RT::Workflow::condition(\$TOP, '$self->{ConditionSatisfy}', '$self->{ConditionFields}') \\} or die "=\$@" } #
EOF

    $res .= ($self->{IsEntryPoint}) ? << 'EOF'
### ENTRY POINT ### { "\nDepends-On: BEGIN\n" } ###############################
EOF
    : << 'EOF';
### NON-ENTRY POINT ### { %{$X{$ID}||{}} or die "Non-Entry!" } ################
EOF

    my %seen;
    my @N;
    my $nextstates;
    foreach my $n (split(/,/, $self->{NextStates})) {
	next unless $n;
	push @N, $n unless $seen{$n}++;
    }
    $self->{NextStates} = join(',', @N);
    $nextstates = join(',', map "'$_'", @N);

    $res .= << "EOF";
{join('',map{"Depended-On-By: ".( \$_ ? ( \$X{"T\$_"}{\$ID}++, "T\$_" ) : "TOP" ).\$/}do{0,
### NEXT STATE ################################################################
$nextstates
###############################################################################
}).join(\$/,map"Requestor: \$_",\$TOP->Requestors->MemberEmailAddresses)}
###############################################################################
EOF

    foreach my $key (@Keys) {
	$res .= "$key: $self->{$key}\n" if length $self->{$key};
    }

    $res .= << "EOF" if (lc($self->Type) eq 'approval');
Owner: { eval \\{ RT::Workflow::owner(\$TOP, '$self->{OwnerClass}', '$self->{OwnerFields}') \\} or die "owner:=\$@" }
EOF

    $self->{Content} = << "EOF" if (lc($self->Type) eq 'code');
require RT::Workflow;
RT::Workflow::action(\$TOP, '$self->{ActionProcedure}', '$self->{ActionFields}');
EOF

    $self->{Content} = << "EOF" if (lc($self->Type) eq 'approval');
Default Approval
EOF

    $res .= << "EOF";
Content-Type: text/plain
Content:
$self->{Content}
ENDOFCONTENT

EOF

    return $res;
}

=begin asd

# Top level tickets
my @Tops = grep { $_->{Id} =~ m/^\d+$/ } @{ $session{Workflow} };

foreach my $self (@Tops) {
    $Content .= _IterateChilds($self, 'Begin');
}
    $ARGS{Content} = $Content;

} # end of if

=cut

eval "require RT::WorkflowEntry_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/WorkflowEntry_Vendor.pm});
eval "require RT::WorkflowEntry_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/WorkflowEntry_Local.pm});

1;
