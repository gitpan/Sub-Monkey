package Sub::Monkey;

our $VERSION = '0.001';
$Sub::Monkey::Subs     = {};
$Sub::Monkey::CanPatch = [];
$Sub::Monkey::Classes  = [];

=head1 NAME

Sub::Monkey - Dynamically and neatly monkey patch a module

=head1 DESCRIPTION

In some cases, rare cases, you may need to temporarily patch a module on-the-go. Sub::Monkey can help you achieve this by providing a set of methods to create, override and add hook modifiers, similar to M<Moose>, but can apply them to remote modules (Not the current one).
This type of monkey patching is reasonably safe because you can plainly see what changes are being made to what modules. Obviously monkey patching isn't always the best alternative, but sometimes you may have no other choice.
Sub::Monkey also provides the ability to undo any patching you made with C<unpatch>.

=head1 SYNOPSIS

    use Sub::Monkey qw<Some::Package>;

    method 'needThisMethod' => sub {
        ...
    },
    qw<Some::Package>;

We just created a brand new method in the Some::Package class. If you attempt to override an existing method using C<method>, then Sub::Monkey will raise an error, because really you should be using C<override> instead.
Remember, to patch a module with Sub::Monkey, you need to explicitly tell it you want to modify a class by importing it when you C<use Sub::Monkey>. To do this for multiple modules just add them all into an array.

    use Sub::Monkey qw<Some::Package Foo::Bar Another::One>;

=head1 METHODS

=cut

sub import {
    my ($class, @args) = @_;
    my $pkg = scalar caller;
    if (scalar @args > 0) {
        for my $m (@args) {
            push @{$Sub::Monkey::CanPatch}, $m;
        }
        _extend_class(\@args, $pkg);
    }

    _import_def(
        $pkg,
        undef,
        qw/
            override
            method
            before
            after
            around
            unpatch
        /
    );
}

sub _extend_class {
    my ($mothers, $class) = @_;

    foreach my $mother (@$mothers) {
        # if class is unknown to us, import it (FIXME)
        unless (grep { $_ eq $mother } @$Sub::Monkey::Classes) {
            eval "use $mother";
            warn "Could not load $mother: $@"
                if $@;

            $mother->import;
        }
        push @$Sub::Monkey::Classes, $class;
    }

    {
        no strict 'refs';
        @{"${class}::ISA"} = @$mothers;
    }
}

sub _import_def {
    my ($pkg, $from, @subs) = @_;
    if ($from) {
        for (@subs) {
            *{$pkg . "::$_"} = \&{"$from\::$_"};
        }
    }
    else {
        for (@subs) {
            *{$pkg . "::$_"} = \&$_;
        }
    }
}

sub _doh {
    my $err = shift;
    die $err . "\n";
}

sub _check_init {
    my $class = shift;

    _doh "No class was specified" if ! $class;

    _doh "Not allowed to patch $class"
        if ! grep { $_ eq $class } @{$Sub::Monkey::CanPatch};
}

sub _add_to_subs {
    my $sub = shift;
    if (! exists $Sub::Monkey::Subs->{$sub}) {
        $Sub::Monkey::Subs->{$sub} = {};
        $Sub::Monkey::Subs->{$sub} = \&{$sub};
    }
}

sub getscope {
    my $self = shift;
    my $pkg = $self||scalar caller;
    return $pkg;
}
# modifiers

=head2 override 

Overrides an already existing method. If the target method doesn't exist then Sub::Monkey will throw an error.

    override 'foo' => sub {
        return "foo bar";
    },
    qw<Some::Module>;

=cut

sub override {
    my ($method, $code, $class) = @_;

    _check_init($class);

    _doh "You need to specify a class to which your overridden method exists"
        if ! $class;

    _doh "Method $method does not exist in $class. Perhaps you meant 'method' instead of 'override'?"
        if ! $class->can($method);

    _add_to_subs("$class\::$method");
    *$method = sub { $code->(@_) };
    *{$class . "::$method"} = \*$method;
}

=head2 method

Creates a brand new method in the target module. It will NOT allow you to override an existing one using this, and will throw an error.

    method 'active_customers' => sub {
        my $self = shift;
        return $self->search({ status => 'active' });
    },
    qw<Schema::ResultSet::Customer>;

=cut

sub method {
    my ($method, $code, $class) = @_;
    
    _check_init($class);
    _doh "You need to specify a class to which your created method will be initialised"
        if ! $class;
    
    _doh "The method '$method' already exists in $class. Did you want to 'override' it instead?"
        if $class->can($method);

    _add_to_subs("$class\::$method");
    *$method = sub { $code->(@_); };

    *{$class . "::$method"} = \*$method;
}

=head2 before

Simply adds code to the target method before the original code is ran

    # Foo.pm
    package Foo;
    
    sub new { return bless {}, __PACKAGE__; }
    sub hello { print "Hello, $self->{name}; }
    1;

    # test.pl
    use Sub::Monkey qw<Foo>;
   
    my $foo = Foo->new; 
    before 'hello' => {
        my $self = shift;
        $self->{name} = 'World';
    },
    qw<Foo>;

    print $foo->hello . "\n";

=cut

sub before {
    my ($method, $code, $class) = @_;
    
    _check_init($class);
    if (ref($method) eq 'ARRAY') {
        for my $subname (@$method) {
            $full = "$class\::$subname";
            my $alter_sub;
            my $new_code;
            my $old_code;
            die "Could not find $subname in the hierarchy for $class\n"
                if ! $class->can($subname);

            $old_code = \&{$full};
            *$subname = sub {
                $code->(@_);
                $old_code->(@_);
            };

            _add_to_subs($full);
            *{$full} = \*$subname;
        }
    }
    else {
        $full = "$class\::$method";
        my $alter_sub;
        my $new_code;
        my $old_code;
        die "Could not find $method in the hierarchy for $class\n"
            if ! $class->can($method);

        $old_code = \&{$full};
        *$method = sub {
            $code->(@_);
            $old_code->(@_);
        };

        _add_to_subs($full);
        *{$full} = \*$method;
    }
}

=head2 after

Basically the same as C<before>, but appends the code specified to the END of the original

=cut

sub after {
    my ($method, $code, $class) = @_;

    _check_init($class);
    $full = "$class\::$method";
    my $alter_sub;
    my $new_code;
    my $old_code;
    die "Could not find $method in the hierarchy for $class\n"
        if ! $class->can($method);

    $old_code = \&{$full};
    *$method = sub {
        $old_code->(@_);
        $code->(@_);
    };

    _add_to_subs($full);
    *{$full} = \*$method;
}

=head2 around

Around gives the user a bit more control over the subroutine. When you create an around method the first argument will be the original method, the second is C<$self> and the third is any arguments passed to the original subroutine. In a away this allows you to control the flow of the entire subroutine.

    package MyFoo;

    sub greet {
        my ($self, $name) = @_;

        print "Hello, $name!\n";
    }

    1;

    # test.pl

    use Sub::Monkey qw<MyFoo>;

    # only call greet if any arguments were passed to MyFoo->greet()
    around 'greet' => sub {
        my $method = shift;
        my $self = shift;

        $self->$method(@_)
            if @_;
    },
    qw<MyFoo>;

=cut

sub around {
    my ($method, $code, $class) = @_;

    $full = "$class\::$method";
    die "Could not find $method in the hierarchy for $class\n"
        if ! $class->can($method);

    my $old_code = \&{$full};
    *$method = sub {
        $code->($old_code, @_);
    };

    _add_to_subs($full);
    *{$full} = \*$method;
}

=head2 unpatch

Undoes any modifications made to patched methods, restoring it to its original state.

    override 'this' => sub { print "Blah\n"; }, qw<FooClass>;
  
    unpatch 'this' => 'FooClass';

=cut

sub unpatch {
    my ($method, $class) = @_;

    my $sub = "$class\::$method";

    if (! exists $Sub::Monkey::Subs->{$sub}) {
        warn "Could not restore $method in $class because I have no recollection of it";
        return 0;
    }

    *{$sub} = $Sub::Monkey::Subs->{$sub};
}

=head1 AUTHOR

Brad Haywood <brad@geeksware.net>

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
