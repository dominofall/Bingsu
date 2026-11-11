// 상대 모듈 + module.exports + __dirname
const fs = require('fs');
const path = require('path');
module.exports = {
  info: () => JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'data', 'info.json'), 'utf8')),
  dataURL: (name) => 'data:image/png;base64,' + fs.readFileSync(path.join(__dirname, '..', 'data', name)).toString('base64'),
};
