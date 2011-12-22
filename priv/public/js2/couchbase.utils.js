Utils = {};

Utils.formatLogTStamp = function(mseconds) {
  var date = new Date(mseconds);
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');

  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  return [
    "<strong>", _2digits(date.getHours()), ':', _2digits(date.getMinutes()),
    ':', _2digits(date.getSeconds()), "</strong> - ", weekDays[date.getDay()],
    ' ', monthNames[date.getMonth()], ' ', date.getDate(), ', ',
    date.getFullYear()].join('');
};

Utils.truncateTo3Digits = function(value, leastScale) {
  var scale = _.detect([100, 10, 1, 0.1, 0.01, 0.001], function (v) {
    return value >= v;
  }) || 0.0001;
  if (leastScale !== undefined && leastScale > scale) {
    scale = leastScale;
  }
  scale = 100 / scale;
  return Math.floor(value*scale)/scale;
};

Utils.formatMemSize = function(value) {
  return Utils.formatQuantity(value, 'B', 1024, ' ');
};

Utils.prepareQuantity = function (value, K) {
  K = K || 1024;
  var M = K*K;
  var G = M*K;
  var T = G*K;

  var t = _.detect([[T,'T'],[G,'G'],[M,'M'],[K,'K']], function (t) {
    return value > 1.1*t[0];
  });
  t = t || [1, ''];
  return t;
};

Utils.formatQuantity = function (value, kind, K, spacing) {
  if (spacing === null) {
    spacing = '';
  }
  if (kind === null) {
    kind = 'B'; //bytes is default
  }

  var t = Utils.prepareQuantity(value, K);
  return [Utils.truncateTo3Digits(value/t[0]), spacing, t[1], kind].join('');
};
