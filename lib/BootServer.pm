package BootServer;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Util qw(dumper);
# This method will run once at server start



has cfg => sub ($self) {
     # Load configuration from hash returned by config file
    $self->plugin('Config', 
        file => $self->home->rel_file('etc/boot-server.cfg')
    );
};

sub startup {
    my $self = shift;
    # Configure the application
    $self->secrets($self->cfg->{secrets});
    # Router
    $self->helper( getDir => sub ($c,$name,$new=0) {
        my $ip = $c->param('mac') || $c->tx->remote_address;
        my $root = $self->cfg->{dataRoot};
        my $dst = $root.'/'.$name;
        if ($new or -e $dst.'__'.$ip){
            $dst .= '__'.$ip;
        }
        return $dst;
    });
    my $r = $self->routes;
    my $root = $self->cfg->{dataRoot};
    my $bootServer = $self->cfg->{bootServer};
    # Normal route to controller
    $r->get('ipxe.cfg' => sub ($c) {
        $c->render(text => <<CFG_END, format => 'txt' );
#!ipxe
set base $bootServer
kernel \${base}/vmlinuz boot=dbrrg ramroot=\${base}/ramroot.tar.xz splash i915.fastboot=0 
initrd \${base}/initrd.img
boot
CFG_END
    });
    $r->get('/<archive>.pkg' => [ archive => [qw(overlay home)] ] => sub ($c) {
        my $name = $c->stash('archive');
        my $dir = $c->getDir($name);
        # Operation that would block the event loop for 5 seconds
        my $sp = Mojo::IOLoop->subprocess( sub ($sp) {
            open my $tar, '-|','tar','-C',$dir,'-zcf','-','.'
                // die "Problem with tar $!";
            my $buffer;
            while (my $bytesread = $tar->read($buffer,1024*1024)) {    
                $sp->progress($buffer);
            }
            close $tar;
            return $?;
        }, sub ($sp, $err, @results) {
            if ($err) {
                $c->log->error($err);
                $c->render( status => 500, text => $err);
            }
            $c->finish;
        });
        $sp->on('progress' => sub ($sp,$data) {
            $c->write($data);
        });
        $c->render_later;
    });
    $r->post('/home.pkg' => sub ($c) {
        return $c->render(text => 'File is too big.', status => 500)
            if $c->req->is_limit_exceeded;
        return $c->render(text => 'Expected an upload in data.', status => 500)     if ref $c->param('data') ne 'Mojo::Upload';
        my $dir = $c->getDir('home',1);
        $c->log->debug("Receiving Update");
        my $data = $c->param('data');
        Mojo::IOLoop->subprocess( sub ($sp) {
            mkdir $dir if not -d $dir;
            open my $tar, '|-', 'tar','-C',$dir,'-zxf','-' 
                // die "Problem with tar $!";
            print $tar $data->slurp;
            close($tar);
            return $?;
        },
        sub ($sp, $err, @results) {
            if ($err) {
                $c->log->error($err);
                $c->render( status => 500, text => $err);
            }
            $c->render( status => 201, text => '');
        });
        $c->render_later;
    });
}

1;
