// Required things
var colors      = require('colors');
    pg          = require('pg-promise')();
    bcrypt      = require('bcrypt');

process.argv[2] ? port = process.argv[2] : port = 9025;
const SMTPServer = require('smtp-server').SMTPServer;
      simpleParser = require('mailparser').simpleParser;

// Extract the domain from the email address
function extractDomain(email){
  var email_string_array = email.split("@");
  var domain_string_location = email_string_array.length -1;
  return email_string_array[domain_string_location];
}

// Readable streams
function streamToString(stream, cb) {
  const chunks = [];
  stream.on('data', (chunk) => {
    chunks.push(chunk.toString());
  });
  stream.on('end', () => {
    cb(chunks.join(''));
  });
}

// Database config
var cn = "postgres://theo@localhost:5432/AuthenticationServices_development";
var db = pg(cn)

var ms_cn = "postgres://theo@localhost:5432/MailServer";
var ms_db = pg(ms_cn)

// Variables we need
var authenticated = 0;
    user_secret   = "0b47f9340ee94b3e223b94651b1a46f7576d3d0ab0aed4697bcf6f155604b99264349cff31c97976ea5377a8b07d0f6df40da78ffe809c6526166820383a0954";
    client_IP     = null;
    rctp_to       = null;
    mail_from     = null;
    path          = null;


// The Server
const server = new SMTPServer({
  secure: false,
  name: "smtp.gomonar.ch",
  banner: "Monarch SMTP Server Ready.",
  disabledCommands: ['STARTTLS'],
  allowInsecureAuth: true,
  disableReverseLookup: true,
  authOptional: true,
  authMethods: ['LOGIN'],
  size: 10 * 1024 * 1024,
  onConnect(session, callback){
    client_IP = session.remoteAddress;
    console.log(`[${session.id}] New client connected from ${session.remoteAddress}`);
        return callback(); // Accept the connection
    },
  onAuth(auth, session, callback){
    if(auth.method !== 'LOGIN'){
            console.log(`[${session.id}] Incorrect auth type (${auth.method}) received from {client_IP}`.yellow);
            return callback(new Error('Expected LOGIN, got '+auth.method));
        }
    db.one('SELECT password_digest FROM users WHERE email = $1', auth.username.toLowerCase())
    .then(user => {
      bcrypt.compare(auth.password, user.password_digest, function(err, res){
        if(res === true){
          // Flip the bit
          authenticated = 1;
          callback(null, {user: auth.username.toLowerCase()});
        } else{
          console.log(`[${session.id}] Incorrect password received from ${client_IP}`)
          return callback(new Error('User or password not recognised.'))
        }
      })
    })
    .catch(error => {
      console.log(`[${session.id}] Incorrect username received from ${client_IP}`.red)
        return callback(new Error('User or password not recognised.'))
    });
  },
  onMailFrom(address, session, callback){
    if(extractDomain(address.address.toLowerCase()) === 'td512.io' && authenticated === 0){
        return callback(new Error('You are not logged in.'));
    }
        mail_from = address.address.toLowerCase();
        return callback(); // Accept the address
    },
  onRcptTo(address, session, callback){
        if(extractDomain(address.address.toLowerCase()) !== 'td512.io' && authenticated === 0){
            return callback(new Error('No such domain.'));
        }
        rctp_to = address.address.toLowerCase();
        console.log(`[${session.id}] New mail for ${rctp_to} from ${mail_from}`)
        return callback(); // Accept the address
    },
    onData(stream, session, callback){
          var mail_message_from        = null;
              mail_message_to          = null;
              mail_message_subject     = null;
              mail_message_cc          = null;
              mail_message_bcc         = null;
              mail_message_priority    = null;
              mail_message_body        = null;
              mail_message_date        = null;

          streamToString(stream, (data) => {
            simpleParser(data, (err, mail)=>{
              mail.headers.has("from") ? mail_message_from = mail.from.text : mail_message_from = "unknown sender";
              mail.headers.has("to") ? mail_message_to = mail.to.text : mail_message_to = null;
              mail.headers.has("subject") ? mail_message_subject = mail.subject : mail_message_subject = "(no subject)";
              mail.headers.has("cc") ? mail_message_cc = mail.cc.text : mail_message_cc = null;
              mail.headers.has("bcc") ? mail_message_bcc = mail.headers.get("bcc") : mail_message_bcc = null;
              mail.headers.has("priority") ? mail_message_priority = mail.headers.get("priority") : mail_message_priority = "normal";
              mail.headers.has("date") ? mail_message_date = mail.headers.get("date") : mail_message_date = new Date(Date.now()).toISOString();
              mail.text ? mail_message_body = mail.text : "(no body)";
              console.log(`[${session.id}] Inserting row.`)
              ms_db.one('INSERT INTO inbox(to_user, from_address, subject, cc, bcc, priority, date, body) VALUES($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id', [mail_message_to, mail_message_from, mail_message_subject, mail_message_cc, mail_message_bcc, mail_message_priority, mail_message_date, mail_message_body])
                .then(data => {
                  console.log(`[${session.id}] Processed mail successfully, row #${data.id}.`)
                })
                .catch(error => {
                    console.log('ERROR: ', error); // print error;
                });
            })
          });
          stream.on('end', callback);
      }
});
process.stdout.write('\x1Bc');
console.log(`Monarch SMTP Daemon listening on port ${port}`.green);
server.listen(port);
server.on('error', err => {
    console.log('Error %s', err.message);
});
